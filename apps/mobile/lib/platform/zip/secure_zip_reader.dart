import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../shared_kernel/failures.dart';

/// One preflighted central-directory entry.
class ZipEntryInfo {
  const ZipEntryInfo({
    required this.path,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.method,
    required this.dataOffset,
  });

  /// Normalized relative path (forward slashes, no `.`/`..`/empty segments).
  final String path;
  final int compressedSize;
  final int uncompressedSize;

  /// 0 = stored, 8 = deflate.
  final int method;

  /// Absolute offset of the entry's data inside the ZIP file.
  final int dataOffset;

  bool get isDeflated => method == 8;
}

/// Security-first ZIP reader for `.readpack` imports (design §6.5, MOB-IMP-001).
///
/// A self-contained implementation so the safety rules live exactly where the
/// threat model is, and no third-party ZIP API leaks into the domain layer:
///
/// - preflight reads the central directory **before** writing anything;
/// - rejects absolute paths, `..`, empty paths, duplicate normalized paths,
///   symlinks/hardlinks, device files, encrypted entries, multi-disk archives,
///   ZIP64 and unsupported compression methods;
/// - enforces entry count, per-entry size and total expanded size limits;
/// - extraction streams with its own byte accounting and must match the
///   declared uncompressed size exactly (declared sizes alone are never
///   trusted). Integrity ultimately relies on the manifest SHA-256 checked by
///   the importer after extraction.
class SecureZipReader {
  const SecureZipReader();

  /// Candidate limits (design §6.5); freeze after phase-0 testing.
  static const maxEntries = 64;
  static const maxEntryBytes = 1024 * 1024 * 1024; // 1 GiB
  static const maxTotalExpandedBytes = 1024 * 1024 * 1024; // 1 GiB
  static const maxPathLength = 240;

  static const _eocdSignature = 0x06054b50;
  static const _centralSignature = 0x02014b50;
  static const _localSignature = 0x04034b50;
  static const _maxCommentSearch = 65557; // 64 KiB comment + EOCD

  static AppFailure _format(String message, [String? detail]) =>
      AppFailure(FailureKind.packageFormat, message, detail: detail);

  static AppFailure _limit(String message, [String? detail]) =>
      AppFailure(FailureKind.resourceLimit, message, detail: detail);

  /// Reads the central directory and returns validated entries.
  ///
  /// Throws [AppFailure] ([FailureKind.packageFormat] or
  /// [FailureKind.resourceLimit]) on any violation. Nothing is written.
  Future<List<ZipEntryInfo>> preflight(File zip) async {
    final raf = await zip.open();
    try {
      final fileSize = await raf.length();
      if (fileSize < 22) {
        throw _format('not a zip file', 'file too small');
      }
      final eocdOffset = await _findEocd(raf, fileSize);
      await raf.setPosition(eocdOffset);
      final eocd = await raf.read(22);
      final bd = ByteData.sublistView(eocd);
      final diskNumber = bd.getUint16(4, Endian.little);
      final cdDisk = bd.getUint16(6, Endian.little);
      if (diskNumber != 0 || cdDisk != 0) {
        throw _format('multi-disk archive not supported');
      }
      final entriesOnDisk = bd.getUint16(8, Endian.little);
      final entryCount = bd.getUint16(10, Endian.little);
      final cdSize = bd.getUint32(12, Endian.little);
      final cdOffset = bd.getUint32(16, Endian.little);
      if (entryCount == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
        throw _format('zip64 not supported');
      }
      if (entriesOnDisk != entryCount) {
        throw _format('corrupt central directory', 'entry count mismatch');
      }
      if (entryCount > maxEntries) {
        throw _limit('too many entries', '$entryCount > $maxEntries');
      }
      if (cdOffset + cdSize > fileSize) {
        throw _format('corrupt central directory', 'out of bounds');
      }

      final entries = <ZipEntryInfo>[];
      final seenPaths = <String>{};
      var totalExpanded = 0;
      await raf.setPosition(cdOffset);
      final cd = await raf.read(cdSize);
      var pos = 0;
      for (var i = 0; i < entryCount; i++) {
        if (pos + 46 > cdSize) {
          throw _format('corrupt central directory', 'truncated entry');
        }
        final head = ByteData.sublistView(cd, pos);
        if (head.getUint32(0, Endian.little) != _centralSignature) {
          throw _format('corrupt central directory', 'bad signature at $i');
        }
        final flags = head.getUint16(8, Endian.little);
        final method = head.getUint16(10, Endian.little);
        final compressedSize = head.getUint32(20, Endian.little);
        final uncompressedSize = head.getUint32(24, Endian.little);
        final nameLength = head.getUint16(28, Endian.little);
        final extraLength = head.getUint16(30, Endian.little);
        final commentLength = head.getUint16(32, Endian.little);
        final localOffset = head.getUint32(42, Endian.little);
        final externalAttributes = head.getUint32(38, Endian.little);

        if (flags & 0x1 != 0) {
          throw _format('encrypted entries not supported');
        }
        if (method != 0 && method != 8) {
          throw _format('unsupported compression method', 'method $method');
        }
        final nameEnd = pos + 46 + nameLength;
        if (nameEnd > cdSize) {
          throw _format('corrupt central directory', 'truncated name');
        }
        final rawName = cd.sublist(pos + 46, nameEnd);
        final path = _normalizePath(rawName);
        if (!seenPaths.add(path)) {
          throw _format('duplicate path', path);
        }
        _checkEntryType(externalAttributes, path);
        if (uncompressedSize > maxEntryBytes) {
          throw _limit('entry too large', path);
        }
        totalExpanded += uncompressedSize;
        if (totalExpanded > maxTotalExpandedBytes) {
          throw _limit('expanded size too large',
              '$totalExpanded > $maxTotalExpandedBytes');
        }
        if (compressedSize > fileSize) {
          throw _format('corrupt entry', path);
        }

        final dataOffset =
            await _localDataOffset(raf, fileSize, localOffset, path);
        if (dataOffset + compressedSize > fileSize) {
          throw _format('corrupt entry data', path);
        }

        entries.add(ZipEntryInfo(
          path: path,
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
          method: method,
          dataOffset: dataOffset,
        ));
        pos = nameEnd + extraLength + commentLength;
      }
      return entries;
    } finally {
      await raf.close();
    }
  }

  /// Streams one preflighted entry to [target] and returns bytes written.
  ///
  /// The actual written count must equal the declared uncompressed size;
  /// mismatch or decompression failure is a package-format error. A failed
  /// extraction always removes its partially written target file.
  Future<int> extractEntry(File zip, ZipEntryInfo entry, File target) async {
    final raf = await zip.open();
    IOSink? sink;
    var completed = false;
    try {
      await raf.setPosition(entry.dataOffset);
      await target.parent.create(recursive: true);
      sink = target.openWrite();
      var written = 0;
      if (entry.method == 0) {
        var remaining = entry.compressedSize;
        while (remaining > 0) {
          final chunk = await raf.read(remaining > _chunk ? _chunk : remaining);
          if (chunk.isEmpty) break;
          remaining -= chunk.length;
          written += chunk.length;
          sink.add(chunk);
        }
      } else {
        final controller =
            StreamController<List<int>>(sync: true);
        final decodeDone =
            _inflate(controller.stream, sink, entry.uncompressedSize);
        // The decode may fail while the read loop below is still feeding
        // chunks (e.g. the expanded-size cut-off); register a listener now
        // so the error is not reported as unhandled before `await` reaches
        // it. The original future still completes with the error.
        decodeDone.ignore();
        var remaining = entry.compressedSize;
        while (remaining > 0) {
          final chunk = await raf.read(remaining > _chunk ? _chunk : remaining);
          if (chunk.isEmpty) break;
          remaining -= chunk.length;
          written += chunk.length;
          controller.add(chunk);
        }
        await controller.close();
        written = await decodeDone;
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (written != entry.uncompressedSize) {
        throw _format('size mismatch after extraction', entry.path);
      }
      completed = true;
      return written;
    } on AppFailure {
      rethrow;
    } catch (e) {
      throw _format('decompression failed', '${entry.path}: $e');
    } finally {
      await sink?.close();
      await raf.close();
      // Never leave a partial extraction behind: the importer treats any
      // leftover file as staged content.
      if (!completed && await target.exists()) {
        await target.delete();
      }
    }
  }

  static const _chunk = 64 * 1024;

  /// Inflates raw-deflate [input] into [sink], counting output bytes and
  /// aborting as soon as more than [maxOutputBytes] would be written.
  Future<int> _inflate(
      Stream<List<int>> input, IOSink sink, int maxOutputBytes) async {
    final outSink = _CountingSink(sink, maxOutputBytes);
    final decoder = ZLibDecoder(raw: true).startChunkedConversion(outSink);
    await for (final chunk in input) {
      decoder.add(chunk);
    }
    decoder.close();
    await outSink.flushed;
    return outSink.count;
  }

  Future<int> _findEocd(RandomAccessFile raf, int fileSize) async {
    final searchSize =
        fileSize < _maxCommentSearch ? fileSize : _maxCommentSearch;
    await raf.setPosition(fileSize - searchSize);
    final tail = await raf.read(searchSize);
    final sig = ByteData(4)..setUint32(0, _eocdSignature, Endian.little);
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == sig.getUint8(0) &&
          tail[i + 1] == sig.getUint8(1) &&
          tail[i + 2] == sig.getUint8(2) &&
          tail[i + 3] == sig.getUint8(3)) {
        final commentLength =
            ByteData.sublistView(tail, i).getUint16(20, Endian.little);
        if (i + 22 + commentLength == tail.length) {
          return fileSize - searchSize + i;
        }
      }
    }
    throw _format('not a zip file', 'end of central directory not found');
  }

  /// Validates and normalizes a raw entry name.
  String _normalizePath(List<int> rawName) {
    final String name;
    try {
      name = utf8.decode(rawName, allowMalformed: false);
    } on FormatException {
      throw _format('invalid utf-8 in path');
    }
    if (name.isEmpty) {
      throw _format('empty path');
    }
    // Treat backslashes as separators so Windows-style zips cannot smuggle
    // distinct names that collide on POSIX normalization.
    final unified = name.replaceAll('\\', '/');
    if (unified.startsWith('/') ||
        unified.length > 1 && unified[1] == ':' && _isAlpha(unified[0])) {
      throw _format('absolute path rejected', name);
    }
    final segments = unified.split('/');
    if (segments.any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw _format('unsafe path rejected', name);
    }
    final normalized = segments.join('/');
    if (normalized.length > maxPathLength) {
      throw _limit('path too long', name);
    }
    return normalized;
  }

  static bool _isAlpha(String ch) {
    final c = ch.codeUnitAt(0);
    return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
  }

  /// Rejects non-regular-file entries via Unix mode bits (when present).
  void _checkEntryType(int externalAttributes, String path) {
    final unixMode = (externalAttributes >> 16) & 0xFFFF;
    if (unixMode == 0) return; // DOS-origin archive; nothing declared.
    const typeMask = 0xF000;
    const regularFile = 0x8000;
    final type = unixMode & typeMask;
    if (type != regularFile) {
      throw _format('non-regular file entry rejected', path);
    }
  }

  /// Locates the entry data behind its local header.
  Future<int> _localDataOffset(
    RandomAccessFile raf,
    int fileSize,
    int localOffset,
    String path,
  ) async {
    if (localOffset + 30 > fileSize) {
      throw _format('corrupt local header', path);
    }
    await raf.setPosition(localOffset);
    final header = await raf.read(30);
    final bd = ByteData.sublistView(header);
    if (bd.getUint32(0, Endian.little) != _localSignature) {
      throw _format('corrupt local header', path);
    }
    final nameLength = bd.getUint16(26, Endian.little);
    final extraLength = bd.getUint16(28, Endian.little);
    return localOffset + 30 + nameLength + extraLength;
  }
}

/// Counts bytes forwarded to an [IOSink] and aborts past [_maxBytes].
class _CountingSink implements ChunkedConversionSink<List<int>> {
  _CountingSink(this._sink, this._maxBytes);

  final IOSink _sink;

  /// Declared uncompressed size of the entry being decoded. A deflate
  /// stream can expand beyond its declaration, so the cut-off happens
  /// mid-write instead of a size reconciliation after the fact.
  final int _maxBytes;

  final Completer<void> _flushed = Completer<void>();
  int count = 0;

  Future<void> get flushed => _flushed.future;

  @override
  void add(List<int> chunk) {
    count += chunk.length;
    if (count > _maxBytes) {
      throw AppFailure(FailureKind.resourceLimit,
          'entry expands beyond its declared size');
    }
    _sink.add(chunk);
  }

  @override
  void close() {
    _sink.flush().then((_) {
      if (!_flushed.isCompleted) _flushed.complete();
    }, onError: (Object e) {
      // Propagate the flush failure; without this the inflate side waits
      // on [flushed] forever.
      if (!_flushed.isCompleted) _flushed.completeError(e);
    });
  }
}
