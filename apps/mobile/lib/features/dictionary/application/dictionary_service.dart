import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../../platform/filesystem/app_directories.dart';
import '../../../platform/http/lan_http_client.dart';
import '../../../shared_kernel/failures.dart';
import '../domain/dictionary_models.dart';
import '../infrastructure/dictionary_dao.dart';
import '../infrastructure/dictionary_database.dart';
import '../infrastructure/dictionary_installer.dart';
import '../infrastructure/dictionary_package_source.dart';

class DictionaryService {
  DictionaryService({
    required DictionaryManifestDao manifestDao,
    required AppDirectories directories,
  }) : _manifestDao = manifestDao,
       _installer = DictionaryInstaller(
         manifestDao: manifestDao,
         directories: directories,
       ),
       status = ValueNotifier<DictionaryStatus>(_initialStatus(manifestDao));

  final DictionaryManifestDao _manifestDao;
  final DictionaryInstaller _installer;
  final ValueNotifier<DictionaryStatus> status;
  DictionaryDatabase? _openDb;
  String? _openPath;

  static DictionaryStatus _initialStatus(DictionaryManifestDao dao) {
    final current = dao.current();
    if (current == null) {
      return const DictionaryStatus(DictionaryResourceState.unavailable);
    }
    if (!current.formatVersion.startsWith('2.') || current.schemaVersion != 2) {
      return DictionaryStatus(
        DictionaryResourceState.incompatible,
        resource: current,
        message: 'installed dictionary requires v2 replacement',
      );
    }
    return DictionaryStatus(
      File(current.path).existsSync()
          ? DictionaryResourceState.available
          : DictionaryResourceState.corrupt,
      resource: current,
      message: File(current.path).existsSync() ? null : 'database file missing',
    );
  }

  DictionaryResource? currentResource() => _manifestDao.current();

  bool get available => status.value.state == DictionaryResourceState.available;

  Future<void> recover() async {
    _closeDatabase();
    try {
      await _installer.recover();
      status.value = _initialStatus(_manifestDao);
    } on AppFailure catch (failure) {
      status.value = DictionaryStatus(
        DictionaryResourceState.corrupt,
        resource: _manifestDao.current(),
        message: failure.message,
      );
    } catch (error) {
      status.value = DictionaryStatus(
        DictionaryResourceState.corrupt,
        resource: _manifestDao.current(),
        message: 'dictionary cleanup failed: $error',
      );
    }
  }

  Future<DictionaryResource> install(
    DictionaryPackageSource source, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final previous = currentResource();
    final previousStatus = status.value.state;
    status.value = DictionaryStatus(
      DictionaryResourceState.installing,
      resource: previous,
    );
    try {
      final resource = await _installer.install(
        source,
        beforeActivate: _closeDatabase,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      status.value = DictionaryStatus(
        DictionaryResourceState.available,
        resource: resource,
      );
      return resource;
    } on AppFailure catch (failure) {
      final stillUsable =
          previous != null &&
          previousStatus == DictionaryResourceState.available &&
          File(previous.path).existsSync();
      status.value = DictionaryStatus(
        stillUsable
            ? DictionaryResourceState.available
            : previous != null
            ? DictionaryResourceState.corrupt
            : failure.kind == FailureKind.packageFormat
            ? DictionaryResourceState.incompatible
            : DictionaryResourceState.unavailable,
        resource: previous,
        message: failure.message,
      );
      rethrow;
    } catch (error) {
      final stillUsable =
          previous != null &&
          previousStatus == DictionaryResourceState.available &&
          File(previous.path).existsSync();
      status.value = DictionaryStatus(
        stillUsable
            ? DictionaryResourceState.available
            : previous == null
            ? DictionaryResourceState.unavailable
            : DictionaryResourceState.corrupt,
        resource: previous,
        message: 'dictionary installation failed: $error',
      );
      rethrow;
    }
  }

  DictionaryDatabase _database(DictionaryResource resource) {
    if (_openDb != null && _openPath == resource.path) return _openDb!;
    _closeDatabase();
    _openDb = DictionaryDatabase.openReadOnly(resource.path);
    _openPath = resource.path;
    return _openDb!;
  }

  static final _edgeNoise = RegExp(
    r"^[\s\p{P}\p{S}]+|[\s\p{P}\p{S}]+$",
    unicode: true,
  );

  static String normalizeSelection(String raw) =>
      raw.replaceAll(_edgeNoise, '').trim();

  static final _innerWhitespace = RegExp(r'\s+');

  static String normalizeLookupKey(String surface) =>
      unorm.nfc(surface).toLowerCase().replaceAll(_innerWhitespace, ' ').trim();

  DictionaryLookup lookup(String rawSelection) {
    final resource = currentResource();
    if (resource == null) return DictionaryLookupUnavailable(rawSelection);
    if (!File(resource.path).existsSync()) {
      status.value = DictionaryStatus(
        DictionaryResourceState.corrupt,
        resource: resource,
        message: 'database file missing',
      );
      _closeDatabase();
      return DictionaryLookupResourceError(
        rawSelection,
        'database file missing',
      );
    }
    final original = rawSelection.trim();
    final originalNormalized = normalizeLookupKey(original);
    if (original.isEmpty) {
      return DictionaryLookupNotFound(
        DictionaryResult(surface: original, normalized: originalNormalized),
      );
    }
    try {
      final db = _database(resource);
      var senses = db.exact(original);
      if (senses.isNotEmpty) {
        return DictionaryLookupFound(
          DictionaryResult(
            surface: original,
            normalized: originalNormalized,
            senses: senses,
          ),
        );
      }
      final surface = normalizeSelection(original);
      final normalized = normalizeLookupKey(surface);
      if (surface.isEmpty) {
        return DictionaryLookupNotFound(
          DictionaryResult(surface: surface, normalized: normalized),
        );
      }
      String? lemma;
      senses = db.normalized(normalized);
      if (senses.isEmpty) {
        final lemmas = db.lemmasFor(normalized).toSet();
        for (final candidate in lemmas) {
          final found = db.normalized(normalizeLookupKey(candidate));
          if (found.isNotEmpty) {
            lemma = candidate;
            senses = found;
            break;
          }
        }
      }
      final result = DictionaryResult(
        surface: surface,
        normalized: normalized,
        lemma: lemma,
        senses: senses,
      );
      return senses.isEmpty
          ? DictionaryLookupNotFound(result)
          : DictionaryLookupFound(result);
    } catch (error) {
      _closeDatabase();
      status.value = DictionaryStatus(
        DictionaryResourceState.corrupt,
        resource: resource,
        message: 'dictionary query failed',
      );
      return DictionaryLookupResourceError(rawSelection, '$error');
    }
  }

  void _closeDatabase() {
    _openDb?.close();
    _openDb = null;
    _openPath = null;
  }

  void dispose() {
    _closeDatabase();
    status.dispose();
  }
}
