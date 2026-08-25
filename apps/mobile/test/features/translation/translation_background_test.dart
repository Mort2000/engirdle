import 'dart:collection';
import 'dart:io' show Directory, SocketException;

import 'package:engirdle_mobile/contracts/readpack_v1/article.dart';
import 'package:engirdle_mobile/features/library/application/library_service.dart';
import 'package:engirdle_mobile/features/library/domain/article_install.dart';
import 'package:engirdle_mobile/features/library/infrastructure/library_dao.dart';
import 'package:engirdle_mobile/features/translation/application/llm_client.dart';
import 'package:engirdle_mobile/features/translation/application/translation_module.dart';
import 'package:engirdle_mobile/features/translation/domain/translation_models.dart';
import 'package:engirdle_mobile/features/translation/application/translation_scheduler.dart';
import 'package:engirdle_mobile/features/translation/infrastructure/deepseek_adapter.dart';
import 'package:engirdle_mobile/features/translation/infrastructure/secret_stores.dart';
import 'package:engirdle_mobile/features/translation/infrastructure/translation_background.dart';
import 'package:engirdle_mobile/features/translation/infrastructure/translation_dao.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:engirdle_mobile/platform/filesystem/app_directories.dart';
import 'package:flutter_test/flutter_test.dart';

/// The session tests ARE the executor: this scheduler only records requests
/// (a waiting_retry backoff delivery is simulated by calling session.run
/// again, exactly like the OS scheduler would).
class RecordingScheduler implements TranslationScheduler {
  final scheduled = <(String, Duration)>[];

  @override
  void schedule(String jobId, {Duration after = Duration.zero}) {
    scheduled.add((jobId, after));
  }

  @override
  void cancelScheduled(String jobId) {}
}

class ScriptedClient implements LlmCompletionClient {
  final _replies = Queue<Object>();

  void reply(String content) => _replies.add(content);
  void fail(LlmException error) => _replies.add(error);

  @override
  Future<LlmCompletion> complete({
    required String model,
    required List<LlmMessage> messages,
    required String thinkingMode,
    required String reasoningEffort,
    required Duration timeout,
  }) async {
    if (_replies.isEmpty) {
      throw StateError('scripted client out of replies');
    }
    final reply = _replies.removeFirst();
    if (reply is LlmException) throw reply;
    return LlmCompletion(
      content: reply as String,
      finishReason: 'stop',
      requestId: 'req',
    );
  }

  @override
  Future<List<String>> listModels({required Duration timeout}) async => [];
}

class RecordingReporter implements TranslationProgressReporter {
  final calls = <String>[];

  @override
  Future<void> progress({
    required String jobId,
    required String title,
    required int done,
    required int total,
  }) async {
    calls.add('progress:$title:$done/$total');
  }

  @override
  Future<void> waiting({required String jobId, required String title}) async {
    calls.add('waiting:$title');
  }

  @override
  Future<void> finished({
    required String jobId,
    required String title,
    required bool succeeded,
  }) async {
    calls.add('finished:$title:${succeeded ? 'ok' : 'fail'}');
  }

  @override
  Future<void> dismiss({required String jobId}) async {
    calls.add('dismiss');
  }
}

void main() {
  late AppDatabase db;
  late LibraryService library;
  late TranslationDao dao;
  late InMemorySecretStore secrets;

  setUp(() {
    db = AppDatabase.inMemory();
    addTearDown(db.close);
    library = LibraryService(
      dao: LibraryDao(db.db),
      directories: AppDirectories(Directory.current),
    );
    dao = TranslationDao(db.db);
    secrets = InMemorySecretStore();
    secrets.write('deepseek-api-key', 'sk-test');
    dao.saveProfile(
      LlmProfile(
        provider: 'deepseek',
        origin: kDeepSeekOfficialOrigin,
        model: 'deepseek-chat',
        secretAlias: 'deepseek-api-key',
        wifiOnly: false,
        chargingOnly: false,
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    );
  });

  void installArticle() {
    library.commitInstall(
      ValidatedArticleImport(
        articleId: 'a1',
        revision: 1,
        artifactRevision: 1,
        title: 'Worker Article',
        source: const ArticleSource(author: 'Engirdle'),
        origin: 'paste',
        formatVersion: 'local-1',
        sourceSha256: 'raw-sha',
        normalizedSha256: 'norm-sha',
        sourceSyntax: 'plain_text',
        structureSha256: 'sha-1',
        segmenterVersion: 'engirdle-segmenter-dart@3',
        blocks: [
          ParsedTextBlock(
            blockId: 'block-1',
            order: 0,
            kind: ArticleTextKind.paragraph,
            sentences: [
              SentenceContent(
                sentenceId: 's1',
                order: 0,
                text: 'One sentence.',
                runs: [
                  ArticleRun(kind: ArticleRunKind.plain, text: 'One sentence.'),
                ],
              ),
              SentenceContent(
                sentenceId: 's2',
                order: 1,
                text: 'Two sentences.',
                runs: [
                  ArticleRun(kind: ArticleRunKind.plain, text: 'Two sentences.'),
                ],
              ),
            ],
          ),
        ],
        manifestJson: '{}',
        attributionJson: '{}',
        artifactSizeBytes: 42,
        artifactSha256: 'raw-sha',
      ),
    );
  }

  TranslationWorkerSession buildSession(
    ScriptedClient client,
    TranslationProgressReporter reporter,
  ) {
    final module = TranslationModule(
      dao: dao,
      library: library,
      client: client,
      secrets: secrets,
      scheduler: RecordingScheduler(),
    );
    return TranslationWorkerSession(
      database: db,
      library: library,
      dao: dao,
      translation: module,
      reporter: reporter,
    );
  }

  test('run reports progress and posts a success summary', () async {
    installArticle();
    // One paragraph block with two sentences = ONE sentence-batch unit, so
    // the reply carries both translations.
    final client = ScriptedClient()..reply('["第一句。", "第二句。"]');
    final reporter = RecordingReporter();
    final session = buildSession(client, reporter);

    final module = session.translationForTest;
    final job = await module.queueTranslation(
      articleId: 'a1',
      privacyConfirmedAt: DateTime.utc(2026, 1, 1),
    );
    final outcome = await session.run(job.jobId);

    expect(outcome, isTrue);
    // Flush the broadcast-stream delivery of the in-run notifications.
    await Future<void>.delayed(Duration.zero);
    // Progress carries the article title and unit counts only (§12.4).
    expect(reporter.calls.first, startsWith('progress:Worker Article:'));
    expect(reporter.calls.last, 'finished:Worker Article:ok');
    expect(library.getContent('a1')!.capabilities.hasTranslation, isTrue);
  });

  test('run reports waiting when the job parks for a retry', () async {
    installArticle();
    final client = ScriptedClient()
      ..fail(const LlmException(LlmErrorKind.server, 'boom'))
      ..fail(const LlmException(LlmErrorKind.server, 'boom'))
      ..fail(const LlmException(LlmErrorKind.server, 'boom'));
    final reporter = RecordingReporter();
    final session = buildSession(client, reporter);

    final module = session.translationForTest;
    final job = await module.queueTranslation(
      articleId: 'a1',
      privacyConfirmedAt: DateTime.utc(2026, 1, 1),
    );
    final outcome = await session.run(job.jobId);

    // Work "succeeded" from WorkManager's view: retry rounds belong to the
    // module's persistent schedule, not to WorkManager retry accounting.
    expect(outcome, isTrue);
    expect(dao.getJob(job.jobId)!.status, TranslationJobStatus.waitingRetry);
    expect(reporter.calls, contains('waiting:Worker Article'));
    // No premature summary while the job is still active.
    expect(
      reporter.calls.where((c) => c.startsWith('finished')),
      isEmpty,
    );
  });

  test('run survives reporter failures and still finishes the job',
      () async {
    installArticle();
    final client = ScriptedClient()..reply('["译文一", "译文二"]');
    final reporter = _ThrowingReporter();
    final session = buildSession(client, reporter);

    final module = session.translationForTest;
    final job = await module.queueTranslation(
      articleId: 'a1',
      privacyConfirmedAt: DateTime.utc(2026, 1, 1),
    );
    final outcome = await session.run(job.jobId);

    expect(outcome, isTrue);
    expect(dao.getJob(job.jobId)!.status, TranslationJobStatus.completed);
  });
}

class _ThrowingReporter implements TranslationProgressReporter {
  @override
  Future<void> progress({
    required String jobId,
    required String title,
    required int done,
    required int total,
  }) async {
    throw const SocketException('notification service gone');
  }

  @override
  Future<void> waiting({required String jobId, required String title}) async {
    throw const SocketException('notification service gone');
  }

  @override
  Future<void> finished({
    required String jobId,
    required String title,
    required bool succeeded,
  }) async {
    throw const SocketException('notification service gone');
  }

  @override
  Future<void> dismiss({required String jobId}) async {
    throw const SocketException('notification service gone');
  }
}
