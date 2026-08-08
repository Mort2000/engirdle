import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:engirdle_mobile/app/dependencies.dart';
import 'package:engirdle_mobile/app/scope.dart';
import 'package:engirdle_mobile/app/theme.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/manifest.dart';
import 'package:engirdle_mobile/contracts/readpack_v1/readpack_validator.dart';
import 'package:engirdle_mobile/features/playback/application/playback_engine.dart';
import 'package:engirdle_mobile/platform/crypto/sha256.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:engirdle_mobile/platform/filesystem/app_directories.dart';
import 'package:engirdle_mobile/platform/http/lan_http_client.dart';
import 'package:engirdle_mobile/platform/zip/secure_zip_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Repository-root contracts directory (tests run with CWD = apps/mobile).
final contractsRoot = Directory(
    p.normalize(p.join(Directory.current.path, '..', '..', 'contracts')));

File readpackFixture(String relative) =>
    File(p.join(contractsRoot.path, 'readpack', 'v1', 'fixtures', relative));

File catalogFixture(String relative) =>
    File(p.join(contractsRoot.path, 'catalog', 'v1', 'fixtures', relative));

/// Extracts [zipFile] with the production reader into a fresh temp directory
/// and runs full cross-file validation.
Future<ValidatedReadpack> extractAndValidate(File zipFile) async {
  final temp = await Directory.systemTemp.createTemp('readpack_contract_');
  addTearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });
  const reader = SecureZipReader();
  final entries = await reader.preflight(zipFile);
  for (final entry in entries) {
    await reader.extractEntry(
        zipFile, entry, File(p.join(temp.path, entry.path)));
  }
  final files = {
    for (final path in ReadpackValidator.requiredPaths)
      path: File(p.join(temp.path, path)),
  };
  return const ReadpackValidator().validate(files, sha256Of: sha256OfFile);
}

/// Parses the manifest of a `.readpack` fixture without full validation.
Future<ReadpackManifest> manifestOf(File zipFile) async {
  final temp = await Directory.systemTemp.createTemp('readpack_manifest_');
  addTearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });
  const reader = SecureZipReader();
  final entries = await reader.preflight(zipFile);
  final manifestEntry = entries.firstWhere((e) => e.path == 'manifest.json');
  final out = File(p.join(temp.path, 'manifest.json'));
  await reader.extractEntry(zipFile, manifestEntry, out);
  return ReadpackManifest.parse(jsonDecode(await out.readAsString()));
}

/// No-op playback engine for unit/widget tests (just_audio is unavailable
/// under `flutter test`).
class FakePlaybackEngine implements PlaybackEngine {
  final _position = StreamController<Duration>.broadcast();
  final _completion = StreamController<void>.broadcast();
  int playClipCalls = 0;
  int playFromCalls = 0;
  int stopCalls = 0;

  @override
  Future<void> playClip({
    required String filePath,
    required Duration start,
    required Duration end,
  }) async {
    playClipCalls++;
  }

  @override
  Future<void> playFrom({required String filePath, required Duration start}) async {
    playFromCalls++;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<void> get completionStream => _completion.stream;

  @override
  Future<void> dispose() async {
    await _position.close();
    await _completion.close();
  }
}

/// Builds a full dependency graph on an in-memory database and a temp data
/// directory. Disposal and temp cleanup are registered automatically.
Future<AppDependencies> newTestDependencies({FakePlaybackEngine? engine}) async {
  final temp = await Directory.systemTemp.createTemp('engirdle_test_');
  final deps = await AppDependencies.build(
    directories: AppDirectories(temp),
    database: AppDatabase.inMemory(),
    engine: engine ?? FakePlaybackEngine(),
    httpClient: LanHttpClient(),
  );
  addTearDown(() async {
    await deps.dispose();
    if (await temp.exists()) await temp.delete(recursive: true);
  });
  return deps;
}

/// Wraps a page with the app scope, palette and theme it expects.
Widget wrapTestWidget(AppDependencies deps, Widget child) {
  const palette = AppPalette.paperPreset;
  return AppScope(
    dependencies: deps,
    child: PaletteScope(
      palette: palette,
      child: MaterialApp(theme: buildTheme(palette), home: child),
    ),
  );
}
