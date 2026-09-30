import 'dart:io';

import 'package:engirdle_mobile/features/library/application/library_service.dart';
import 'package:engirdle_mobile/features/library/infrastructure/library_dao.dart';
import 'package:engirdle_mobile/features/playback/domain/lease_registry.dart';
import 'package:engirdle_mobile/features/playback/infrastructure/library_playback_source_adapter.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:engirdle_mobile/platform/filesystem/app_directories.dart';
import 'package:engirdle_mobile/shared_kernel/content_identity.dart';
import 'package:engirdle_mobile/shared_kernel/failures.dart';
import 'package:engirdle_mobile/features/translation/infrastructure/translation_dao.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final sourceRef = ArticleRef(articleId: 'a1', revision: 1, artifactRevision: 0);

/// Upgrade-cleanup and delete must respect the playback lease (design §6.3),
/// and the source adapter pins/releases around acquire.
void main() {
  late Directory temp;
  late AppDirectories dirs;
  late AppDatabase appDb;
  late LeaseRegistry registry;
  late LibraryService library;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('library_lease_');
    dirs = AppDirectories(temp);
    await dirs.ensureBaseLayout();
    appDb = AppDatabase.inMemory();
    registry = LeaseRegistry();
    library = LibraryService(
      dao: LibraryDao(appDb.db),
      directories: dirs,
      playbackLeases: registry,
      packagedTranslationInstaller: TranslationDao(
        appDb.db,
      ).installPackagedSetFor,
    );
  });

  tearDown(() async {
    appDb.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> writeArtifact(ArticleRef ref) async {
    final dir = dirs.articleDir(
      ref.articleId,
      ref.revision,
      ref.artifactRevision,
    );
    final audio = File(p.join(dir.path, 'audio', 'article.m4a'));
    await audio.create(recursive: true);
    await audio.writeAsBytes(const [0, 1, 2, 3]);
  }

  void installArticle() {
    final db = appDb.db;
    db.execute(
      "INSERT INTO articles (article_id, title, author, source_display_name, "
      "source_url, revision, current_artifact_revision, installed_at) "
      "VALUES ('a1','T','Au','s','http://x',1,0,'2026-01-01T00:00:00Z')",
    );
    db.execute(
      "INSERT INTO article_artifacts (article_id, artifact_revision, "
      "ingress_kind, package_id, format_version, size_bytes, sha256, "
      "manifest_json, attribution_json, installed_at) VALUES "
      "('a1',0,'catalog','pkg','v1',4,'abc','{}','{}',"
      "'2026-01-01T00:00:00Z')",
    );
    db.execute(
      "INSERT INTO blocks (article_id, block_id, kind, ord) VALUES ('a1','b1','p',0)",
    );
    db.execute(
      "INSERT INTO sentences (article_id, block_id, sentence_id, ord, text) "
      "VALUES ('a1','b1','s1',0,'hello')",
    );
    db.execute(
      "INSERT INTO sentences (article_id, block_id, sentence_id, ord, text) "
      "VALUES ('a1','b1','s2',1,'world')",
    );
    db.execute(
      "INSERT INTO translation_sets (translation_set_id, article_id, "
      "artifact_revision, target_locale, origin, status, created_at) VALUES "
      "('set-a1','a1',0,'zh-Hans','packaged','complete',"
      "'2026-01-01T00:00:00Z')",
    );
    db.execute(
      "INSERT INTO sentence_translations (translation_set_id, sentence_id, "
      "text) VALUES ('set-a1','s1','你好')",
    );
    db.execute(
      "INSERT INTO sentence_translations (translation_set_id, sentence_id, "
      "text) VALUES ('set-a1','s2','世界')",
    );
    db.execute(
      "INSERT INTO article_active_translations (article_id, target_locale, "
      "translation_set_id) VALUES ('a1','zh-Hans','set-a1')",
    );
    db.execute(
      "INSERT INTO narration_assets (narration_id, article_id, "
      "artifact_revision, audio_path, codec, sample_rate_hz, channels, "
      "duration_ms) VALUES ('narr-a1','a1',0,'audio/article.m4a','aac',"
      "44100,1,2000)",
    );
    db.execute(
      "INSERT INTO sentence_audio_ranges (narration_id, sentence_id, "
      "audio_start_ms, audio_end_ms, audio_start_sample, audio_end_sample) "
      "VALUES ('narr-a1','s1',0,1000,0,44100)",
    );
    db.execute(
      "INSERT INTO sentence_audio_ranges (narration_id, sentence_id, "
      "audio_start_ms, audio_end_ms, audio_start_sample, audio_end_sample) "
      "VALUES ('narr-a1','s2',1000,2000,44100,88200)",
    );
  }

  group('upgrade cleanup respects leases', () {
    test('an unleased old artifact is removed', () async {
      final old = ArticleRef(articleId: 'a1', revision: 1, artifactRevision: 0);
      final current = ArticleRef(
        articleId: 'a1',
        revision: 2,
        artifactRevision: 0,
      );
      await writeArtifact(old);
      await writeArtifact(current);

      await library.cleanupOldArtifacts(current);

      expect(dirs.articleDir('a1', 1, 0).existsSync(), isFalse);
      expect(dirs.articleDir('a1', 2, 0).existsSync(), isTrue);
    });

    test(
      'a leased old artifact is skipped, then cleaned after release',
      () async {
        installArticle();
        // The installed version is now revision 2; retryCleanup re-reads it
        // from the DAO rather than trusting the caller's ref.
        appDb.db.execute(
          "UPDATE articles SET revision = 2 WHERE article_id = 'a1'",
        );
        final old = ArticleRef(
          articleId: 'a1',
          revision: 1,
          artifactRevision: 0,
        );
        final current = ArticleRef(
          articleId: 'a1',
          revision: 2,
          artifactRevision: 0,
        );
        await writeArtifact(old);
        await writeArtifact(current);

        // A background session holds the old artifact's audio.
        final oldAudio = File(
          p.join(dirs.articleDir('a1', 1, 0).path, 'audio', 'article.m4a'),
        );
        registry.pin(articleId: 'a1', path: oldAudio.path);

        await library.cleanupOldArtifacts(current);
        expect(dirs.articleDir('a1', 1, 0).existsSync(), isTrue); // skipped

        registry.unpin(oldAudio.path);
        await library.retryCleanup(current);
        expect(
          dirs.articleDir('a1', 1, 0).existsSync(),
          isFalse,
        ); // now removed
      },
    );
  });

  group('delete refuses while leased', () {
    test(
      'deleting the active article throws and leaves artifacts on disk',
      () async {
        await writeArtifact(sourceRef);
        registry.pin(
          articleId: 'a1',
          path: '/data/articles/a1/1/0/audio/article.m4a',
        );

        await expectLater(
          library.deleteArticle('a1'),
          throwsA(isA<AppFailure>()),
        );
        expect(dirs.articleRootDir('a1').existsSync(), isTrue); // untouched
      },
    );
  });

  group('retryCleanup with a stale lease ref', () {
    // Regression: a lease releases with the ref it acquired, which an upgrade
    // may have superseded while the session was playing. retryCleanup must
    // re-read the current version from the DAO — passing the stale ref
    // through would keep the old artifact and delete the live one.
    test(
      'an upgraded article keeps its current artifact, drops the stale one',
      () async {
        installArticle();
        // The installed version is now revision 2 (upgrade committed mid-play).
        appDb.db.execute(
          "UPDATE articles SET revision = 2 WHERE article_id = 'a1'",
        );
        final stale = ArticleRef(
          articleId: 'a1',
          revision: 1,
          artifactRevision: 0,
        );
        await writeArtifact(stale);
        await writeArtifact(
          ArticleRef(articleId: 'a1', revision: 2, artifactRevision: 0),
        );

        // The released lease still carries the pre-upgrade ref.
        await library.retryCleanup(stale);

        expect(
          dirs.articleDir('a1', 1, 0).existsSync(),
          isFalse,
        ); // stale removed
        expect(
          dirs.articleDir('a1', 2, 0).existsSync(),
          isTrue,
        ); // current kept
      },
    );

    test('an article deleted while leased is left untouched', () async {
      await writeArtifact(sourceRef);
      // No DB row (the delete landed right after the lease released): there is
      // no current version to clean against.
      await library.retryCleanup(sourceRef);
      expect(dirs.articleDir('a1', 1, 0).existsSync(), isTrue);
    });
  });

  group('source adapter', () {
    test('acquire pins the audio path and returns ordered ranges', () async {
      installArticle();
      await writeArtifact(sourceRef);
      final adapter = LibraryPlaybackSourceAdapter(
        library: library,
        registry: registry,
      );

      final lease = await adapter.acquire(sourceRef);

      expect(lease.title, 'T');
      expect(lease.author, 'Au');
      expect(lease.ranges.map((r) => r.sentenceId), ['s1', 's2']);
      expect(lease.ranges.first.label, '第 1 段第 1 句');
      expect(registry.isLeased(lease.audioFilePath), isTrue);

      adapter.release(lease);
      expect(registry.isLeased(lease.audioFilePath), isFalse);
    });

    test('a stale (non-current) ref fails fast without pinning', () async {
      installArticle();
      await writeArtifact(sourceRef);
      final adapter = LibraryPlaybackSourceAdapter(
        library: library,
        registry: registry,
      );

      final stale = ArticleRef(
        articleId: 'a1',
        revision: 2,
        artifactRevision: 0,
      );
      await expectLater(adapter.acquire(stale), throwsA(isA<StateError>()));
      expect(registry.isLeasedArticle('a1'), isFalse);
    });
  });
}
