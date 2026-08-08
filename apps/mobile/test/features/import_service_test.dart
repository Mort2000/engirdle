import 'dart:io';

import 'package:engirdle_mobile/contracts/catalog_v1/catalog.dart';
import 'package:engirdle_mobile/features/importer/application/import_service.dart';
import 'package:engirdle_mobile/features/importer/domain/import_models.dart';
import 'package:engirdle_mobile/features/importer/infrastructure/import_log_dao.dart';
import 'package:engirdle_mobile/features/library/application/library_service.dart';
import 'package:engirdle_mobile/features/library/infrastructure/library_dao.dart';
import 'package:engirdle_mobile/platform/crypto/sha256.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:engirdle_mobile/platform/filesystem/app_directories.dart';
import 'package:engirdle_mobile/platform/http/lan_http_client.dart';
import 'package:engirdle_mobile/platform/zip/secure_zip_reader.dart';
import 'package:engirdle_mobile/shared_kernel/content_identity.dart';
import 'package:engirdle_mobile/shared_kernel/failures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_helpers.dart';

/// End-to-end import pipeline against a loopback server serving the real
/// contract fixture (MOB-DL-001, MOB-IMP-001/002/003).
void main() {
  late Directory temp;
  late AppDatabase appDb;
  late AppDirectories dirs;
  late LibraryService library;
  late ImportLogDao logDao;
  late ImportService importer;
  late HttpServer server;

  final fixture = readpackFixture('valid/minimal.readpack');

  Future<CatalogPackage> catalogEntryFor(File zip, {String? name}) async {
    final manifest = await manifestOf(zip);
    return CatalogPackage(
      articleId: manifest.articleId,
      revision: manifest.revision,
      artifactRevision: manifest.artifactRevision,
      title: 'Minimal Contract Article',
      formatVersion: manifest.formatVersion,
      size: await zip.length(),
      sha256: await sha256OfFile(zip),
      url: Uri.parse(
          'http://127.0.0.1:${server.port}/packages/${name ?? 'minimal.readpack'}'),
    );
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('import_test_');
    dirs = AppDirectories(temp);
    await dirs.ensureBaseLayout();
    appDb = AppDatabase.inMemory();
    library = LibraryService(dao: LibraryDao(appDb.db), directories: dirs);
    logDao = ImportLogDao(appDb.db);
    importer = ImportService(
      logDao: logDao,
      library: library,
      httpClient: LanHttpClient(timeout: const Duration(seconds: 5)),
      directories: dirs,
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final served = switch (request.uri.path) {
        '/packages/minimal.readpack' => fixture,
        '/packages/missing-translation.readpack' =>
          readpackFixture('invalid/missing-translation.readpack'),
        _ => null,
      };
      if (served != null) {
        final bytes = await served.readAsBytes();
        request.response.headers.contentLength = bytes.length;
        request.response.add(bytes);
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    appDb.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('imports the valid fixture end to end', () async {
    final package = await catalogEntryFor(fixture);
    final phases = <ImportPhase>[];
    final progress = <(int, int?)>[];

    final ref = await importer.importPackage(
      package,
      onPhase: phases.add,
      onDownloadProgress: (received, total) => progress.add((received, total)),
    );

    // Returned identity matches the catalog announcement.
    expect(ref.articleId, package.articleId);
    expect(ref.revision, package.revision);

    // The library pointer switched: article, blocks and sentences readable.
    final article = library.getArticle(package.articleId);
    expect(article, isNotNull);
    expect(article!.title, 'Minimal Contract Article');
    expect(article.revision, package.revision);
    final content = library.getContent(package.articleId)!;
    expect(content.blocks, isNotEmpty);
    expect(content.sentences, isNotEmpty);

    // The audio path handed to playback must resolve to the real file
    // (readpack layout puts it under audio/, not the artifact root).
    expect(File(content.audioFilePath).existsSync(), isTrue);

    // The immutable artifact directory holds exactly the four v1 files.
    final artifactDir = library.artifactDirectory(ref);
    final artifactFiles = <String>[];
    await for (final entity in artifactDir.list(recursive: true)) {
      if (entity is File) {
        artifactFiles.add(p.relative(entity.path, from: artifactDir.path));
      }
    }
    expect(
        artifactFiles,
        unorderedEquals([
          'manifest.json',
          'article.json',
          'attribution.json',
          p.join('audio', 'article.m4a'),
        ]));

    // All phases ran in order, download progress reached the declared size.
    expect(phases, containsAllInOrder(ImportPhase.values));
    expect(progress.last.$1, package.size);
    expect(progress.last.$2, package.size);

    // No recovery log, temp download or staging leftovers remain.
    expect(logDao.unfinished(), isEmpty);
    expect(await dirs.downloadsDir().list().isEmpty, isTrue);
    expect(
        await Directory(p.join(temp.path, 'staging')).list().isEmpty, isTrue);
  });

  test('a tampered package leaves the library untouched and no residue',
      () async {
    final package = await catalogEntryFor(fixture);
    final forged = CatalogPackage(
      articleId: package.articleId,
      revision: package.revision,
      artifactRevision: package.artifactRevision,
      title: package.title,
      formatVersion: package.formatVersion,
      size: package.size,
      sha256: '0' * 64, // catalog lies: the download will not match
      url: package.url,
    );

    await expectLater(
      importer.importPackage(forged),
      throwsA(isA<AppFailure>()
          .having((f) => f.kind, 'kind', FailureKind.download)
          .having((f) => f.message, 'message', 'sha256 mismatch')),
    );

    expect(library.getArticle(package.articleId), isNull);
    expect(logDao.unfinished(), isEmpty);
    expect(await dirs.downloadsDir().list().isEmpty, isTrue);
    expect(
        await Directory(p.join(temp.path, 'staging')).list().isEmpty, isTrue);
    expect(await library.artifactDirectory(package.ref).exists(), isFalse);
  });

  test('an http failure keeps everything clean', () async {
    final package = await catalogEntryFor(fixture);
    final missing = CatalogPackage(
      articleId: package.articleId,
      revision: package.revision,
      artifactRevision: package.artifactRevision,
      title: package.title,
      formatVersion: package.formatVersion,
      size: package.size,
      sha256: package.sha256,
      url: Uri.parse('http://127.0.0.1:${server.port}/packages/missing.bin'),
    );
    await expectLater(
      importer.importPackage(missing),
      throwsA(isA<AppFailure>()
          .having((f) => f.kind, 'kind', FailureKind.connection)),
    );
    expect(library.getArticle(package.articleId), isNull);
    expect(logDao.unfinished(), isEmpty);
    expect(await dirs.downloadsDir().list().isEmpty, isTrue);
  });

  test('recoverUnfinished drops interrupted downloads', () async {
    // Simulate a crash mid-download: a log row plus partial temp files.
    const importId = '11111111-1111-4111-8111-111111111111';
    final download = dirs.downloadFile(importId);
    await download.parent.create(recursive: true);
    await download.writeAsBytes([1, 2, 3]);
    final staging = dirs.stagingDir(importId);
    await staging.create(recursive: true);
    logDao.insert(ImportOperation(
      importId: importId,
      articleId: 'article-x',
      revision: 1,
      artifactRevision: 1,
      title: 'X',
      packageUrl: 'http://127.0.0.1/x.readpack',
      expectedSize: 3,
      expectedSha256: '0' * 64,
      state: ImportState.downloading,
      stagingPath: staging.path,
    ));

    await importer.recoverUnfinished();

    expect(await download.exists(), isFalse);
    expect(await staging.exists(), isFalse);
    expect(logDao.unfinished(), isEmpty);
    expect(library.getArticle('article-x'), isNull);
  });

  test('recoverUnfinished replays a committed cleanup', () async {
    // First install the real article so cleanup has a current artifact.
    final package = await catalogEntryFor(fixture);
    final ref = await importer.importPackage(package);

    // Simulate a crash after commit: a stray download file plus a log row.
    const importId = '22222222-2222-4222-8222-222222222222';
    final download = dirs.downloadFile(importId);
    await download.parent.create(recursive: true);
    await download.writeAsBytes([9]);
    logDao.insert(ImportOperation(
      importId: importId,
      articleId: ref.articleId,
      revision: ref.revision,
      artifactRevision: ref.artifactRevision,
      title: 'Minimal Contract Article',
      packageUrl: package.url.toString(),
      expectedSize: 1,
      expectedSha256: '0' * 64,
      state: ImportState.committed,
      stagingPath: dirs.stagingDir(importId).path,
    ));

    await importer.recoverUnfinished();

    expect(await download.exists(), isFalse);
    expect(logDao.unfinished(), isEmpty);
    // The installed article is untouched.
    expect(library.getArticle(ref.articleId), isNotNull);
  });

  test('a contract violation is classified as a package-format failure',
      () async {
    // Passes download/hash/preflight/extraction, then fails cross-file
    // validation (a sentence without translation) with a ContractViolation.
    final broken = readpackFixture('invalid/missing-translation.readpack');
    final package =
        await catalogEntryFor(broken, name: 'missing-translation.readpack');

    await expectLater(
      importer.importPackage(package),
      throwsA(isA<AppFailure>()
          .having((f) => f.kind, 'kind', FailureKind.packageFormat)
          .having(
              (f) => f.message, 'message', 'package contract violation')),
    );

    // Nothing installed, no residue.
    expect(library.getArticle(package.articleId), isNull);
    expect(logDao.unfinished(), isEmpty);
    expect(await dirs.downloadsDir().list().isEmpty, isTrue);
    expect(
        await Directory(p.join(temp.path, 'staging')).list().isEmpty, isTrue);
    expect(await library.artifactDirectory(package.ref).exists(), isFalse);
  });

  test('recoverUnfinished replays a moving commit when the artifact is valid',
      () async {
    final package = await catalogEntryFor(fixture);
    final ref = package.ref;
    // Crash after the move, before the DB commit: the artifact directory is
    // complete on disk and the log row is still in `moving`.
    final finalDir = library.artifactDirectory(ref);
    const reader = SecureZipReader();
    for (final entry in await reader.preflight(fixture)) {
      await reader.extractEntry(
          fixture, entry, File(p.join(finalDir.path, entry.path)));
    }
    const importId = '33333333-3333-4333-8333-333333333333';
    logDao.insert(ImportOperation(
      importId: importId,
      articleId: ref.articleId,
      revision: ref.revision,
      artifactRevision: ref.artifactRevision,
      title: package.title,
      packageUrl: package.url.toString(),
      expectedSize: package.size,
      expectedSha256: package.sha256,
      state: ImportState.moving,
      stagingPath: dirs.stagingDir(importId).path,
    ));

    await importer.recoverUnfinished();

    // The commit was replayed: the article is installed and readable.
    final article = library.getArticle(ref.articleId);
    expect(article, isNotNull);
    expect(article!.revision, ref.revision);
    expect(article.artifactRevision, ref.artifactRevision);
    expect(library.getContent(ref.articleId)!.blocks, isNotEmpty);
    expect(logDao.unfinished(), isEmpty);
  });

  test(
      'recoverUnfinished rolls back a moving commit when the artifact is broken',
      () async {
    final package = await catalogEntryFor(fixture);
    final ref = package.ref;
    // Crash mid-move: the artifact directory holds garbage.
    final finalDir = library.artifactDirectory(ref);
    await finalDir.create(recursive: true);
    await File(p.join(finalDir.path, 'manifest.json')).writeAsString('{broken');
    const importId = '44444444-4444-4444-8444-444444444444';
    logDao.insert(ImportOperation(
      importId: importId,
      articleId: ref.articleId,
      revision: ref.revision,
      artifactRevision: ref.artifactRevision,
      title: package.title,
      packageUrl: package.url.toString(),
      expectedSize: package.size,
      expectedSha256: package.sha256,
      state: ImportState.moving,
      stagingPath: dirs.stagingDir(importId).path,
    ));

    await importer.recoverUnfinished();

    // Rolled back: the directory is deleted and nothing is installed.
    expect(await finalDir.exists(), isFalse);
    expect(library.getArticle(ref.articleId), isNull);
    expect(logDao.unfinished(), isEmpty);
  });

  test('recoverUnfinished with a stale committed ref keeps current artifacts',
      () async {
    // Install rev A, then simulate a newer install (rev A+1 artifacts plus
    // the DB pointer moved forward) while a stale `committed` log row from
    // the rev-A import still names the old ref.
    final package = await catalogEntryFor(fixture);
    final ref = await importer.importPackage(package);
    final newerRef = ArticleRef(
      articleId: ref.articleId,
      revision: ref.revision,
      artifactRevision: ref.artifactRevision + 1,
    );
    final newerDir = library.artifactDirectory(newerRef);
    const reader = SecureZipReader();
    for (final entry in await reader.preflight(fixture)) {
      await reader.extractEntry(
          fixture, entry, File(p.join(newerDir.path, entry.path)));
    }
    appDb.db.execute(
      'UPDATE articles SET artifact_revision = ? WHERE article_id = ?',
      [newerRef.artifactRevision, ref.articleId],
    );
    const importId = '55555555-5555-4555-8555-555555555555';
    logDao.insert(ImportOperation(
      importId: importId,
      articleId: ref.articleId,
      revision: ref.revision,
      artifactRevision: ref.artifactRevision,
      title: package.title,
      packageUrl: package.url.toString(),
      expectedSize: package.size,
      expectedSha256: package.sha256,
      state: ImportState.committed,
      stagingPath: dirs.stagingDir(importId).path,
    ));

    await importer.recoverUnfinished();

    // The current (newer) artifacts survive; the stale row is dropped.
    expect(await newerDir.exists(), isTrue);
    final article = library.getArticle(ref.articleId);
    expect(article, isNotNull);
    expect(article!.artifactRevision, newerRef.artifactRevision);
    expect(logDao.unfinished(), isEmpty);
  });

  test('recoverUnfinished skips rows with an unknown state', () async {
    // A row written by a newer app version must not block recovery of the
    // others, and must itself be left untouched.
    const badId = '66666666-6666-4666-8666-666666666666';
    logDao.insert(ImportOperation(
      importId: badId,
      articleId: 'article-x',
      revision: 1,
      artifactRevision: 1,
      title: 'X',
      packageUrl: 'http://127.0.0.1/x.readpack',
      expectedSize: 1,
      expectedSha256: '0' * 64,
      state: ImportState.downloading,
      stagingPath: dirs.stagingDir(badId).path,
    ));
    appDb.db.execute(
        "UPDATE import_operations SET state = 'future-state' "
        'WHERE import_id = ?',
        [badId]);
    // A normal interrupted download behind it must still be recovered.
    const goodId = '77777777-7777-4777-8777-777777777777';
    final download = dirs.downloadFile(goodId);
    await download.parent.create(recursive: true);
    await download.writeAsBytes([1, 2, 3]);
    logDao.insert(ImportOperation(
      importId: goodId,
      articleId: 'article-y',
      revision: 1,
      artifactRevision: 1,
      title: 'Y',
      packageUrl: 'http://127.0.0.1/y.readpack',
      expectedSize: 3,
      expectedSha256: '0' * 64,
      state: ImportState.downloading,
      stagingPath: dirs.stagingDir(goodId).path,
    ));

    await importer.recoverUnfinished();

    expect(await download.exists(), isFalse);
    expect(logDao.unfinished(), isEmpty);
    final remaining =
        appDb.db.select('SELECT import_id FROM import_operations');
    expect(remaining.length, 1);
    expect(remaining.first['import_id'], badId);
  });
}
