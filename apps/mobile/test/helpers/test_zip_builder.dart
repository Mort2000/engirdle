import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Minimal ZIP writer for reader tests: local headers + central directory +
/// EOCD, no extras/comments. Lets tests forge declared sizes, flags and Unix
/// modes to exercise preflight limits without huge payloads.
class TestZipBuilder {
  final _entries = <_ZipRecord>[];

  /// Adds a stored (method 0) entry.
  void addStored(
    String path,
    List<int> data, {
    int? declaredUncompressedSize,
    int flags = 0,
    int unixMode = 0,
  }) {
    _entries.add(_ZipRecord(
      path: path,
      method: 0,
      compressed: data,
      declaredUncompressedSize: declaredUncompressedSize ?? data.length,
      flags: flags,
      unixMode: unixMode,
    ));
  }

  /// Adds a deflated (method 8, raw deflate) entry.
  void addDeflated(
    String path,
    List<int> data, {
    int? declaredUncompressedSize,
    int flags = 0,
    int unixMode = 0,
  }) {
    final compressed = ZLibEncoder(raw: true).convert(data);
    _entries.add(_ZipRecord(
      path: path,
      method: 8,
      compressed: compressed,
      declaredUncompressedSize: declaredUncompressedSize ?? data.length,
      flags: flags,
      unixMode: unixMode,
    ));
  }

  List<int> build() {
    final out = BytesBuilder(copy: false);
    final central = BytesBuilder(copy: false);
    for (final e in _entries) {
      final nameBytes = utf8.encode(e.path);
      final localOffset = out.length;

      final local = ByteData(30 + nameBytes.length);
      local.setUint32(0, 0x04034b50, Endian.little);
      local.setUint16(4, 20, Endian.little); // version needed
      local.setUint16(6, e.flags, Endian.little);
      local.setUint16(8, e.method, Endian.little);
      // mod time/date left zero.
      local.setUint32(14, 0, Endian.little); // crc32 (reader does not check)
      local.setUint32(18, e.compressed.length, Endian.little);
      local.setUint32(22, e.declaredUncompressedSize, Endian.little);
      local.setUint16(26, nameBytes.length, Endian.little);
      local.setUint16(28, 0, Endian.little); // extra length
      local.buffer.asUint8List().setRange(30, 30 + nameBytes.length, nameBytes);
      out.add(local.buffer.asUint8List());
      out.add(e.compressed);

      final cd = ByteData(46 + nameBytes.length);
      cd.setUint32(0, 0x02014b50, Endian.little);
      cd.setUint16(4, 20, Endian.little); // version made by
      cd.setUint16(6, 20, Endian.little); // version needed
      cd.setUint16(8, e.flags, Endian.little);
      cd.setUint16(10, e.method, Endian.little);
      cd.setUint32(16, 0, Endian.little); // crc32
      cd.setUint32(20, e.compressed.length, Endian.little);
      cd.setUint32(24, e.declaredUncompressedSize, Endian.little);
      cd.setUint16(28, nameBytes.length, Endian.little);
      // extra 0, comment 0, disk 0, internal attrs 0.
      cd.setUint32(38, e.unixMode << 16, Endian.little); // external attrs
      cd.setUint32(42, localOffset, Endian.little);
      cd.buffer.asUint8List().setRange(46, 46 + nameBytes.length, nameBytes);
      central.add(cd.buffer.asUint8List());
    }

    final cdBytes = central.takeBytes();
    final cdOffset = out.length;
    out.add(cdBytes);

    final eocd = ByteData(22);
    eocd.setUint32(0, 0x06054b50, Endian.little);
    eocd.setUint16(4, 0, Endian.little); // disk number
    eocd.setUint16(6, 0, Endian.little); // central directory disk
    eocd.setUint16(8, _entries.length, Endian.little);
    eocd.setUint16(10, _entries.length, Endian.little);
    eocd.setUint32(12, cdBytes.length, Endian.little);
    eocd.setUint32(16, cdOffset, Endian.little);
    eocd.setUint16(20, 0, Endian.little); // comment length
    out.add(eocd.buffer.asUint8List());
    return out.takeBytes();
  }
}

class _ZipRecord {
  const _ZipRecord({
    required this.path,
    required this.method,
    required this.compressed,
    required this.declaredUncompressedSize,
    required this.flags,
    required this.unixMode,
  });

  final String path;
  final int method;
  final List<int> compressed;
  final int declaredUncompressedSize;
  final int flags;
  final int unixMode;
}
