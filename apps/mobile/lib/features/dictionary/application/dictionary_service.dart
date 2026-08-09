import 'dart:io';

import 'package:flutter/foundation.dart';

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
    await _installer.recover();
    status.value = _initialStatus(_manifestDao);
  }

  Future<DictionaryResource> install(
    DictionaryPackageSource source, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final previous = currentResource();
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
      final stillUsable = previous != null && File(previous.path).existsSync();
      status.value = DictionaryStatus(
        stillUsable
            ? DictionaryResourceState.available
            : failure.kind == FailureKind.packageFormat
            ? DictionaryResourceState.incompatible
            : DictionaryResourceState.corrupt,
        resource: stillUsable ? previous : null,
        message: failure.message,
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
      surface.toLowerCase().replaceAll(_innerWhitespace, ' ').trim();

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
    final surface = normalizeSelection(rawSelection);
    final normalized = normalizeLookupKey(surface);
    final empty = DictionaryResult(surface: surface, normalized: normalized);
    if (surface.isEmpty) return DictionaryLookupNotFound(empty);
    try {
      final db = _database(resource);
      var senses = db.exact(surface);
      String? lemma;
      if (senses.isEmpty) senses = db.normalized(normalized);
      if (senses.isEmpty) {
        final lemmas = db.lemmasFor(normalized).toSet();
        for (final candidate in lemmas) {
          final found = db.normalized(candidate.toLowerCase());
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
