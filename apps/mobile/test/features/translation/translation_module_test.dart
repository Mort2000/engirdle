import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:engirdle_mobile/contracts/readpack_v1/article.dart';
import 'package:engirdle_mobile/features/library/application/library_service.dart';
import 'package:engirdle_mobile/features/library/domain/article_install.dart';
import 'package:engirdle_mobile/features/library/domain/installed_article.dart';
import 'package:engirdle_mobile/features/library/infrastructure/library_dao.dart';
import 'package:engirdle_mobile/features/translation/application/llm_client.dart';
import 'package:engirdle_mobile/features/translation/application/translation_module.dart';
import 'package:engirdle_mobile/features/translation/application/translation_scheduler.dart';
import 'package:engirdle_mobile/features/translation/domain/translation_models.dart';
import 'package:engirdle_mobile/features/translation/infrastructure/deepseek_adapter.dart';
import 'package:engirdle_mobile/features/translation/infrastructure/secret_stores.dart';
import 'package:engirdle_mobile/features/translation/infrastructure/translation_dao.dart'
    show TranslationDao, TranslationClaim;
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:engirdle_mobile/platform/filesystem/app_directories.dart';
import 'package:flutter_test/flutter_test.dart';

/// The scripted LLM adapter (design §7.3): records every request, replays
/// queued replies (or throws), and can gate one reply for cancel races.
class ScriptedLlmClient implements LlmCompletionClient {
  final requests = <List<LlmMessage>>[];
  final _replies = Queue<Object>();

  /// Thrown when the reply queue is empty (endless failure mode).
  LlmException? defaultFailure;
  var _call = 0;

  void reply(String content) => _replies.add(content);
  void fail(LlmException error) => _replies.add(error);
  void gate(Completer<String> completer) => _replies.add(completer);

  @override
  Future<LlmCompletion> complete({
    required String model,
    required List<LlmMessage> messages,
    required String thinkingMode,
    required String reasoningEffort,
    required Duration timeout,
  }) async {
    requests.add(messages);
    if (_replies.isEmpty) {
      final fallback = defaultFailure;
      if (fallback != null) throw fallback;
      throw StateError('scripted client out of replies');
    }
    final reply = _replies.removeFirst();
    if (reply is LlmException) throw reply;
    if (reply is Completer<String>) {
      return LlmCompletion(
        content: await reply.future,
        finishReason: 'stop',
        requestId: 'req-${_call++}',
      );
    }
    return LlmCompletion(
      content: reply as String,
      finishReason: 'stop',
      requestId: 'req-${_call++}',
    );
  }

  @override
  Future<List<String>> listModels({required Duration timeout}) async => [];

  /// Everything ever sent, for leak assertions.
  String get allWire => [
    for (final messages in requests) messages.map((m) => m.content).join('\n'),
  ].join('\n');
}

class ManualScheduler implements TranslationScheduler {
  final scheduled = <String>[];
  final scheduledAfter = <(String, Duration)>[];
  final cancelled = <String>[];

  @override
  void schedule(String jobId, {Duration after = Duration.zero}) {
    scheduled.add(jobId);
    scheduledAfter.add((jobId, after));
  }

  @override
  void cancelScheduled(String jobId) => cancelled.add(jobId);
}

void main() {
  late AppDatabase db;
  late LibraryService library;
  late TranslationDao dao;
  late InMemorySecretStore secrets;
  late ScriptedLlmClient client;
  late ManualScheduler scheduler;

  setUp(() {
    db = AppDatabase.inMemory();
    addTearDown(db.close);
    dao = TranslationDao(db.db);
    library = LibraryService(
      dao: LibraryDao(db.db),
      directories: AppDirectories(Directory.current),
      packagedTranslationInstaller: TranslationDao(db.db).installPackagedSetFor,
    );
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
    client = ScriptedLlmClient();
    scheduler = ManualScheduler();
  });

  /// [longWaitNeverCompletes] models process death: waits at or above one
  /// minute block forever, exactly like a backoff timer that never fires
  /// because the app died first.
  TranslationModule buildModule(
    LlmCompletionClient llmClient, {
    bool longWaitNeverCompletes = false,
    Duration Function(int retryRound)? backoff,
    Future<void> Function(Duration)? sleeper,
  }) => TranslationModule(
    dao: dao,
    library: library,
    client: llmClient,
    secrets: secrets,
    scheduler: scheduler,
    sleeper:
        sleeper ??
        (duration) =>
            longWaitNeverCompletes && duration >= const Duration(minutes: 1)
            ? Completer<void>().future
            : Future<void>.delayed(duration),
    backoffFor: backoff ?? (_) => Duration.zero,
  );

  ArticleRun plain(String text) =>
      ArticleRun(kind: ArticleRunKind.plain, text: text);

  void installArticle({
    String articleId = 'a1',
    String structureSha256 = 'sha-1',
    bool withPackagedTranslation = false,
  }) {
    final blocks = <ParsedBlock>[
      ParsedTextBlock(
        blockId: 'block-1',
        order: 0,
        kind: ArticleTextKind.heading,
        level: 2,
        sentences: [
          SentenceContent(
            sentenceId: 's1',
            order: 0,
            text: 'Title heading.',
            runs: [plain('Title heading.')],
          ),
        ],
      ),
      ParsedTextBlock(
        blockId: 'block-2',
        order: 1,
        kind: ArticleTextKind.paragraph,
        sentences: [
          SentenceContent(
            sentenceId: 's2',
            order: 0,
            text: 'Keep the source text apart.',
            runs: [
              plain('Keep the '),
              ArticleRun(kind: ArticleRunKind.code, text: 'source text'),
              plain(' apart.'),
            ],
          ),
          SentenceContent(
            sentenceId: 's3',
            order: 1,
            text: 'See https://example.com/x for details.',
            runs: [
              plain('See '),
              ArticleRun(
                kind: ArticleRunKind.link,
                text: 'https://example.com/x',
                href: 'https://example.com/x',
              ),
              plain(' for details.'),
            ],
          ),
        ],
      ),
      ParsedTableBlock(
        blockId: 'block-3',
        order: 2,
        alignments: [TableAlignment.inherit, TableAlignment.center],
        translationById: const {},
        header: [
          ParsedTableCell(cellId: 'c0', text: 'Layer', runs: [plain('Layer')]),
          ParsedTableCell(cellId: 'c1', text: 'File', runs: [plain('File')]),
        ],
        rows: [
          [
            ParsedTableCell(cellId: 'c2', text: 'base', runs: [plain('base')]),
            ParsedTableCell(
              cellId: 'c3',
              text: 'article.json',
              runs: [
                ArticleRun(kind: ArticleRunKind.code, text: 'article.json'),
              ],
            ),
          ],
        ],
      ),
      ParsedCodeBlock(blockId: 'block-4', order: 3, code: 'def secret():\n'),
      ParsedDividerBlock(blockId: 'block-5', order: 4),
    ];
    library.commitInstall(
      ValidatedArticleImport(
        articleId: articleId,
        revision: 1,
        artifactRevision: 1,
        title: 'Contract Article',
        source: const ArticleSource(author: 'Engirdle'),
        origin: 'paste',
        formatVersion: 'local-1',
        sourceSha256: 'raw-$structureSha256',
        normalizedSha256: 'norm-$structureSha256',
        sourceSyntax: 'plain_text',
        structureSha256: structureSha256,
        segmenterVersion: 'engirdle-segmenter-dart@3',
        blocks: blocks,
        manifestJson: '{}',
        attributionJson: '{}',
        artifactSizeBytes: 42,
        artifactSha256: 'raw-$structureSha256',
        translation: withPackagedTranslation
            ? PackagedTranslationImport(
                locale: 'zh-Hans',
                pipelineJson: '{"origin": "packaged"}',
                sentences: const [
                  ('s1', '既有标题译文'),
                  ('s2', '既有正文译文'),
                  ('s3', '既有链接译文'),
                ],
                cells: const [
                  ('block-3', 'c0', '层'),
                  ('block-3', 'c1', '文件'),
                  ('block-3', 'c2', '基座'),
                  ('block-3', 'c3', 'article.json'),
                ],
              )
            : null,
      ),
    );
  }

  void queueValidReplies() {
    client
      ..reply('["标题译文"]')
      ..reply('["保持 ‰0‰ 分离。", "参见 ‰1‰ 了解详情。"]')
      ..reply(
        '{"block_id": "block-3", "columns": 2, '
        '"alignments": ["default", "center"], '
        '"header": [{"cell_id": "c0", "text": "层"}, '
        '{"cell_id": "c1", "text": "文件"}], '
        '"rows": [[{"cell_id": "c2", "text": "基座"}, '
        '{"cell_id": "c3", "text": "‰0‰"}]]}',
      );
  }

  Future<TranslationJobSnapshot> queueAndRun() async {
    final module = buildModule(client);
    final job = await module.queueTranslation(
      articleId: 'a1',
      privacyConfirmedAt: DateTime.utc(2026, 1, 1),
    );
    await module.runJob(job.jobId);
    return dao.getJob(job.jobId)!;
  }

  test('queue → checkpoint → complete → atomic activation', () async {
    installArticle();
    queueValidReplies();

    final module = buildModule(client);
    final estimate = module.estimate('a1');
    expect(estimate.unitCount, 3);
    expect(estimate.sentenceCount, 3);
    expect(estimate.tableCount, 1);
    expect(estimate.contextTooLarge, isFalse);

    final job = await queueAndRun();
    expect(job.status, TranslationJobStatus.completed);
    expect(job.completedUnits, 3);
    expect(job.errorKind, isNull);

    // Atomic activation: the reader now sees the whole set at once.
    final content = library.getContent('a1')!;
    expect(content.capabilities.hasTranslation, isTrue);
    final s2 = content.sentences.firstWhere((s) => s.sentenceId == 's2');
    expect(s2.translationZh, '保持 source text 分离。');
    final s3 = content.sentences.firstWhere((s) => s.sentenceId == 's3');
    expect(s3.translationZh, contains('https://example.com/x'));
    final table = content.blocks.whereType<InstalledTableBlock>().single;
    expect(table.translationById['c3'], 'article.json');

    // Full sequential replay: each request grows with accepted history.
    expect(client.requests, hasLength(3));
    expect(client.requests[0], hasLength(3)); // system + context + unit 0
    expect(client.requests[1], hasLength(5)); // + unit0 turns
    expect(client.requests[2], hasLength(7)); // + unit1 turns
    expect(client.requests[1][2].content, '["Title heading."]');
    expect(client.requests[1][3].content, '["标题译文"]');
    expect(
      client.requests[2][4].content,
      '["Keep the ‰0‰ apart.", "See ‰1‰ for details."]',
    );
    expect(client.requests[2][5].content, '["保持 ‰0‰ 分离。", "参见 ‰1‰ 了解详情。"]');

    // Code bodies and hrefs never leave the device in any request.
    expect(client.allWire.contains('def secret'), isFalse);
    expect(client.allWire.contains('https://example.com/x'), isFalse);
    // The API key never appears anywhere near the wire either.
    expect(client.allWire.contains('sk-test'), isFalse);
  });

  test('journal checkpoint survives a process restart and resumes', () async {
    installArticle();
    // Process A: unit 0 accepted, then a hard transport failure. The long
    // backoff models a process that dies before the retry timer fires.
    client
      ..reply('["标题译文"]')
      ..fail(const LlmException(LlmErrorKind.server, 'boom'))
      ..fail(const LlmException(LlmErrorKind.server, 'boom'))
      ..fail(const LlmException(LlmErrorKind.server, 'boom'));
    final module = buildModule(
      client,
      longWaitNeverCompletes: true,
      backoff: (round) => round == 0 ? Duration.zero : const Duration(hours: 1),
    );
    final jobA = await module.queueTranslation(
      articleId: 'a1',
      privacyConfirmedAt: DateTime.utc(2026, 1, 1),
    );
    await module.runJob(jobA.jobId);
    var job = dao.getJob(jobA.jobId)!;
    expect(job.status, TranslationJobStatus.waitingRetry);
    expect(job.completedUnits, 1);
    // Partial results are invisible to the reader.
    expect(library.getContent('a1')!.capabilities.hasTranslation, isFalse);

    // Process B (new module on the same DB) recovers and finishes.
    final clientB = ScriptedLlmClient()
      ..reply('["保持 ‰0‰ 分离。", "参见 ‰1‰ 了解详情。"]')
      ..reply(
        '{"block_id": "block-3", "columns": 2, '
        '"alignments": ["default", "center"], '
        '"header": [{"cell_id": "c0", "text": "层"}, '
        '{"cell_id": "c1", "text": "文件"}], '
        '"rows": [[{"cell_id": "c2", "text": "基座"}, '
        '{"cell_id": "c3", "text": "‰0‰"}]]}',
      );
    final moduleB = buildModule(clientB);
    await moduleB.recover();
    // Scheduled once at queue time and re-scheduled by recovery.
    expect(scheduler.scheduled.last, jobA.jobId);
    await moduleB.runJob(jobA.jobId);
    job = dao.getJob(jobA.jobId)!;
    expect(job.status, TranslationJobStatus.completed);

    // Unit 0 was NOT re-requested: the first call of process B is unit 1,
    // with unit 0's accepted turns replayed from the journal.
    expect(clientB.requests, hasLength(2));
    expect(clientB.requests[0], hasLength(5));
    expect(clientB.requests[0][2].content, '["Title heading."]');
    expect(clientB.requests[0][3].content, '["标题译文"]');
    expect(
      clientB.requests[0][4].content,
      '["Keep the ‰0‰ apart.", "See ‰1‰ for details."]',
    );
    expect(library.getContent('a1')!.capabilities.hasTranslation, isTrue);
  });

  test(
    'cancel during an in-request backoff aborts before any re-send',
    () async {
      installArticle();
      client.defaultFailure = const LlmException(LlmErrorKind.server, 'boom');
      // §9.2: the user cancels while the first retry's backoff sleep is still
      // running (e.g. waiting out a Retry-After). The worker must stop inside
      // the sleep — not send the article body a second time.
      final module = buildModule(client);
      final job = await module.queueTranslation(
        articleId: 'a1',
        privacyConfirmedAt: DateTime.utc(2026, 1, 1),
      );
      final cancelOnFirstSleep = TranslationModule(
        dao: dao,
        library: library,
        client: client,
        secrets: secrets,
        scheduler: scheduler,
        sleeper: (duration) {
          module.cancel(job.jobId);
          return Future<void>.value();
        },
        backoffFor: (_) => const Duration(seconds: 30),
      );
      await cancelOnFirstSleep.runJob(job.jobId);

      expect(client.requests, hasLength(1));
      final after = dao.getJob(job.jobId)!;
      expect(after.status, TranslationJobStatus.cancelled);
      expect(after.translationSetId, isNull);
      expect(dao.acceptedUnits(job.jobId), isEmpty);
      expect(library.getContent('a1')!.capabilities.hasTranslation, isFalse);
    },
  );

  test('cancel during an in-flight request discards the late reply', () async {
    installArticle();
    final gate = Completer<String>();
    client.gate(gate);
    final module = buildModule(client);
    final job = await module.queueTranslation(
      articleId: 'a1',
      privacyConfirmedAt: DateTime.utc(2026, 1, 1),
    );
    final running = module.runJob(job.jobId);
    await Future<void>.delayed(Duration.zero);
    module.cancel(job.jobId);
    gate.complete('["迟到响应"]');
    await running;

    final after = dao.getJob(job.jobId)!;
    expect(after.status, TranslationJobStatus.cancelled);
    expect(after.translationSetId, isNull);
    expect(dao.acceptedUnits(job.jobId), isEmpty);
    expect(library.getContent('a1')!.capabilities.hasTranslation, isFalse);
  });

  test(
    'auth failure stops the job and keeps the checkpoint for retry',
    () async {
      installArticle();
      client
        ..reply('["标题译文"]')
        ..fail(const LlmException(LlmErrorKind.auth, 'rejected'));
      var job = await queueAndRun();
      expect(job.status, TranslationJobStatus.failed);
      expect(job.errorKind, TranslationErrorKind.auth);
      expect(job.completedUnits, 1);

      // Same-config retry resumes from the checkpoint.
      client
        ..reply('["保持 ‰0‰ 分离。", "参见 ‰1‰ 了解详情。"]')
        ..reply(
          '{"block_id": "block-3", "columns": 2, '
          '"alignments": ["default", "center"], '
          '"header": [{"cell_id": "c0", "text": "层"}, '
          '{"cell_id": "c1", "text": "文件"}], '
          '"rows": [[{"cell_id": "c2", "text": "基座"}, '
          '{"cell_id": "c3", "text": "‰0‰"}]]}',
        );
      final retryModule = buildModule(client);
      retryModule.retry(job.jobId);
      await retryModule.runJob(job.jobId);
      job = dao.getJob(job.jobId)!;
      expect(job.status, TranslationJobStatus.completed);
      // Two requests in the failed run (unit 0 accepted, unit 1 rejected)
      // plus two in the retry run (units 1 and 2 only — no re-translation).
      expect(client.requests.length, 2 + 2);
    },
  );

  test(
    'transient failures cycle waiting_retry then fail after the budget',
    () async {
      installArticle();
      client.defaultFailure = const LlmException(
        LlmErrorKind.rateLimit,
        'throttled',
      );
      final module = buildModule(
        client,
        longWaitNeverCompletes: true,
        backoff: (round) =>
            round == 0 ? Duration.zero : const Duration(hours: 1),
      );
      var job = await module.queueTranslation(
        articleId: 'a1',
        privacyConfirmedAt: DateTime.utc(2026, 1, 1),
      );
      // Deterministic round driving: the blocked sleeper freezes the backoff
      // timers (the process-death model), and the test performs the requeue a
      // fired timer would have done. 3 in-request attempts per run, 5
      // waiting_retry rounds, then failure.
      var guard = 0;
      while (dao.getJob(job.jobId)!.status != TranslationJobStatus.failed) {
        if (dao.getJob(job.jobId)!.status ==
            TranslationJobStatus.waitingRetry) {
          dao.requeue(job.jobId);
        }
        await module.runJob(job.jobId);
        guard++;
        if (guard > 20) fail('retry rounds never exhausted');
      }
      job = dao.getJob(job.jobId)!;
      expect(job.status, TranslationJobStatus.failed);
      expect(job.errorKind, TranslationErrorKind.transport);
      expect(job.retryRound, 5);
      expect(client.requests, hasLength(3 * 6));
    },
  );

  test('an unclassified execution error fails the job instead of leaving it '
      'running', () async {
    installArticle();
    // Not an LlmException, protocol error or StateError: without the runJob
    // fallback this class of bug parks the row in running while the host
    // scheduler reports success — a dead task.
    final module = buildModule(_ExplodingClient());
    final job = await module.queueTranslation(
      articleId: 'a1',
      privacyConfirmedAt: DateTime.utc(2026, 1, 1),
    );
    final result = await module.runJob(job.jobId);

    expect(result, TranslationRunResult.ran);
    final failed = dao.getJob(job.jobId)!;
    expect(failed.status, TranslationJobStatus.failed);
    expect(failed.errorKind, TranslationErrorKind.internal);
    expect(failed.errorDetail, contains('corrupt internal state'));
  });

  test('a failing job never disturbs the active packaged set', () async {
    installArticle(withPackagedTranslation: true);
    final before = library.getContent('a1')!;
    expect(before.capabilities.hasTranslation, isTrue);
    client.fail(const LlmException(LlmErrorKind.auth, 'rejected'));
    final job = await queueAndRun();
    expect(job.status, TranslationJobStatus.failed);
    final after = library.getContent('a1')!;
    expect(after.capabilities.hasTranslation, isTrue);
    final s1 = after.sentences.firstWhere((s) => s.sentenceId == 's1');
    expect(s1.translationZh, '既有标题译文');
  });

  test(
    'a re-imported or deleted article removes its job and never activates',
    () async {
      installArticle();
      client.reply('["标题译文"]');
      final module = buildModule(client);
      final job = await module.queueTranslation(
        articleId: 'a1',
        privacyConfirmedAt: DateTime.utc(2026, 1, 1),
      );
      // The article is re-imported with a different structure before the job
      // runs: the base row is replaced, and the cascade removes the job and
      // its building set outright — stale results can never activate.
      installArticle(structureSha256: 'sha-2');
      await module.runJob(job.jobId);
      expect(dao.getJob(job.jobId), isNull);
      expect(client.requests, isEmpty);
      expect(library.getContent('a1')!.capabilities.hasTranslation, isFalse);
      // No orphaned translation rows survive the reinstall.
      expect(
        db.db
            .select('SELECT COUNT(*) AS n FROM sentence_translations')
            .first['n'],
        0,
      );
    },
  );

  test(
    'queue refuses without profile, key or with an oversized article',
    () async {
      installArticle();
      final module = buildModule(client);
      // No key.
      await secrets.delete('deepseek-api-key');
      await expectLater(
        module.queueTranslation(
          articleId: 'a1',
          privacyConfirmedAt: DateTime.utc(2026, 1, 1),
        ),
        throwsA(
          isA<TranslationQueueRefusal>().having(
            (e) => e.kind,
            'kind',
            TranslationErrorKind.auth,
          ),
        ),
      );
      await secrets.write('deepseek-api-key', 'sk-test');

      // Already active job.
      final job = await module.queueTranslation(
        articleId: 'a1',
        privacyConfirmedAt: DateTime.utc(2026, 1, 1),
      );
      await expectLater(
        module.queueTranslation(
          articleId: 'a1',
          privacyConfirmedAt: DateTime.utc(2026, 1, 1),
        ),
        throwsA(isA<TranslationQueueRefusal>()),
      );
      module.cancel(job.jobId);

      // Oversized article: the first request alone busts the window reserve.
      final hugeBlocks = <ParsedBlock>[
        for (var i = 0; i < 2100; i++)
          ParsedTextBlock(
            blockId: 'big-$i',
            order: i,
            kind: ArticleTextKind.paragraph,
            sentences: [
              SentenceContent(
                sentenceId: 'big-s-$i',
                order: 0,
                text: 'x' * 80,
                runs: [plain('x' * 80)],
              ),
            ],
          ),
      ];
      library.commitInstall(
        ValidatedArticleImport(
          articleId: 'a2',
          revision: 1,
          artifactRevision: 1,
          title: 'Huge',
          source: const ArticleSource(),
          origin: 'paste',
          formatVersion: 'local-1',
          sourceSha256: 'huge-raw',
          structureSha256: 'huge-sha',
          blocks: hugeBlocks,
          manifestJson: '{}',
          attributionJson: '{}',
          artifactSizeBytes: 42,
          artifactSha256: 'huge-raw',
        ),
      );
      final estimate = module.estimate('a2');
      expect(estimate.contextTooLarge, isTrue);
      await expectLater(
        module.queueTranslation(
          articleId: 'a2',
          privacyConfirmedAt: DateTime.utc(2026, 1, 1),
        ),
        throwsA(
          isA<TranslationQueueRefusal>().having(
            (e) => e.kind,
            'kind',
            TranslationErrorKind.contextLimit,
          ),
        ),
      );
    },
  );

  test('pause and resume drive the state machine', () async {
    installArticle();
    queueValidReplies();
    final module = buildModule(client);
    final job = await module.queueTranslation(
      articleId: 'a1',
      privacyConfirmedAt: DateTime.utc(2026, 1, 1),
    );
    module.pause(job.jobId);
    expect(dao.getJob(job.jobId)!.status, TranslationJobStatus.paused);
    // A paused job cannot claim.
    await module.runJob(job.jobId);
    expect(dao.getJob(job.jobId)!.status, TranslationJobStatus.paused);
    expect(client.requests, isEmpty);

    module.resume(job.jobId);
    expect(scheduler.scheduled.last, job.jobId);
    await module.runJob(job.jobId);
    expect(dao.getJob(job.jobId)!.status, TranslationJobStatus.completed);
  });

  test(
    'recovery leaves paused jobs paused and terminal states immutable',
    () async {
      installArticle();
      queueValidReplies();
      final module = buildModule(client);
      final job = await module.queueTranslation(
        articleId: 'a1',
        privacyConfirmedAt: DateTime.utc(2026, 1, 1),
      );
      module.pause(job.jobId);
      final scheduledBefore = scheduler.scheduled.length;
      await module.recover();
      // §8.3: only the user resumes a paused job; recovery must not (the only
      // schedule entry so far is the original queue-time one).
      expect(dao.getJob(job.jobId)!.status, TranslationJobStatus.paused);
      expect(scheduler.scheduled.length, scheduledBefore);

      // Terminal states are immutable: a late failure can't flip a cancelled
      // job (the finalize/cancel race guard).
      dao.requeue(job.jobId);
      expect(dao.claim(job.jobId), TranslationClaim.claimed);
      final generation = dao.getJob(job.jobId)!.generation;
      module.cancel(job.jobId);
      // The DAO refuses terminal-state overwrites loudly (finalize race guard).
      expect(
        () => dao.updateStatus(
          job.jobId,
          TranslationJobStatus.failed,
          errorKind: TranslationErrorKind.protocol,
        ),
        throwsA(isA<StateError>()),
      );
      expect(dao.getJob(job.jobId)!.status, TranslationJobStatus.cancelled);
      expect(dao.holdsLease(job.jobId, generation), isFalse);
    },
  );

  test('watch emits live job snapshots', () async {
    installArticle();
    queueValidReplies();
    final module = buildModule(client);
    final statuses = <TranslationJobStatus>[];
    final job = await module.queueTranslation(
      articleId: 'a1',
      privacyConfirmedAt: DateTime.utc(2026, 1, 1),
    );
    final sub = module.watch(job.jobId).listen((s) => statuses.add(s.status));
    await module.runJob(job.jobId);
    await Future<void>.delayed(Duration.zero);
    // The stream opens with the current snapshot (queued), then follows
    // the live state machine to completion.
    expect(statuses.first, TranslationJobStatus.queued);
    expect(statuses, contains(TranslationJobStatus.running));
    expect(statuses.last, TranslationJobStatus.completed);
    await sub.cancel();
  });

  test(
    'a delivered backoff execution takes over the waiting_retry job',
    () async {
      installArticle();
      client
        ..reply('["标题译文"]')
        ..fail(const LlmException(LlmErrorKind.server, 'boom'))
        ..fail(const LlmException(LlmErrorKind.server, 'boom'))
        ..fail(const LlmException(LlmErrorKind.server, 'boom'));
      final module = buildModule(
        client,
        backoff: (round) =>
            round == 0 ? Duration.zero : const Duration(hours: 1),
      );
      final job = await module.queueTranslation(
        articleId: 'a1',
        privacyConfirmedAt: DateTime.utc(2026, 1, 1),
      );
      await module.runJob(job.jobId);
      expect(dao.getJob(job.jobId)!.status, TranslationJobStatus.waitingRetry);
      // The module delegated the backoff window to the scheduler (§8.3) and
      // sleeps nothing itself — the delay survives process death because the
      // adapter persists it, not the process.
      expect(scheduler.scheduledAfter.last, (
        job.jobId,
        const Duration(hours: 1),
      ));

      // The delayed execution is delivered (fired timer or OS backoff):
      // re-entry flips waiting_retry → queued and resumes from the journal.
      client
        ..reply('["保持 ‰0‰ 分离。", "参见 ‰1‰ 了解详情。"]')
        ..reply(
          '{"block_id": "block-3", "columns": 2, '
          '"alignments": ["default", "center"], '
          '"header": [{"cell_id": "c0", "text": "层"}, '
          '{"cell_id": "c1", "text": "文件"}], '
          '"rows": [[{"cell_id": "c2", "text": "基座"}, '
          '{"cell_id": "c3", "text": "‰0‰"}]]}',
        );
      await module.runJob(job.jobId);
      expect(dao.getJob(job.jobId)!.status, TranslationJobStatus.completed);
      expect(library.getContent('a1')!.capabilities.hasTranslation, isTrue);
    },
  );

  test(
    'a redelivered execution takes over a job left running by process death',
    () async {
      installArticle();
      queueValidReplies();
      final module = buildModule(client);
      final job = await module.queueTranslation(
        articleId: 'a1',
        privacyConfirmedAt: DateTime.utc(2026, 1, 1),
      );
      // The process died mid-run: the job stays claimed (running) and its
      // executor is gone; the OS scheduler redelivers the interrupted work.
      expect(dao.claim(job.jobId), isNotNull);
      await module.runJob(job.jobId);
      expect(dao.getJob(job.jobId)!.status, TranslationJobStatus.completed);
      expect(client.requests, hasLength(3));
    },
  );

  test('pause and cancel drop pending scheduled executions', () async {
    installArticle();
    final module = buildModule(client);
    final job = await module.queueTranslation(
      articleId: 'a1',
      privacyConfirmedAt: DateTime.utc(2026, 1, 1),
    );
    module.pause(job.jobId);
    expect(scheduler.cancelled, [job.jobId]);
    module.resume(job.jobId);
    module.cancel(job.jobId);
    expect(scheduler.cancelled, [job.jobId, job.jobId]);
  });

  test(
    'external sync re-emits worker-engine completion to this engine',
    () async {
      installArticle();
      queueValidReplies();
      final moduleA = buildModule(client);
      final job = await moduleA.queueTranslation(
        articleId: 'a1',
        privacyConfirmedAt: DateTime.utc(2026, 1, 1),
      );
      var libraryNotifications = 0;
      library.changes.listen((_) => libraryNotifications++);
      // Long interval: the test drives ticks manually (a UI-engine observer
      // with a worker engine committing on another connection, §9.2).
      moduleA.startExternalSync(interval: const Duration(hours: 1));

      // The "worker engine": a second module instance running on the same
      // database. Its in-process notify reaches only its own listeners.
      final moduleB = TranslationModule(
        dao: dao,
        library: library,
        client: client,
        secrets: secrets,
        scheduler: scheduler,
      );
      await moduleB.runJob(job.jobId);
      expect(
        moduleA.jobById(job.jobId)!.status,
        TranslationJobStatus.completed,
      );

      // The observer notices the terminal transition through the jobs table,
      // re-emits changes and pings the library so readers refresh (§12.3).
      moduleA.pollExternalChanges();
      expect(libraryNotifications, 1);
      moduleA.dispose();
    },
  );

  test(
    'deleting an article drops its pending scheduled execution (§12.1)',
    () async {
      installArticle();
      final module = buildModule(client);
      final job = await module.queueTranslation(
        articleId: 'a1',
        privacyConfirmedAt: DateTime.utc(2026, 1, 1),
      );
      module.startExternalSync(interval: const Duration(hours: 1));
      expect(scheduler.cancelled, isEmpty);

      // The article (and with it the job row) is deleted while the execution
      // is still pending.
      await library.deleteArticle('a1');
      expect(dao.getJob(job.jobId), isNull);

      module.pollExternalChanges();
      expect(scheduler.cancelled, [job.jobId]);
      module.dispose();
    },
  );

  test('a second job defers while another is executing (§8.4)', () async {
    installArticle();
    installArticle(articleId: 'a2', structureSha256: 'sha-2');
    final module = buildModule(client);
    final jobA = await module.queueTranslation(
      articleId: 'a1',
      privacyConfirmedAt: DateTime.utc(2026, 1, 1),
    );
    final jobB = await module.queueTranslation(
      articleId: 'a2',
      privacyConfirmedAt: DateTime.utc(2026, 1, 1),
    );

    // Job A holds the single execution slot with an in-flight request.
    final gate = Completer<String>();
    client.gate(gate);
    client
      ..reply('["保持 ‰0‰ 分离。", "参见 ‰1‰ 了解详情。"]')
      ..reply(
        '{"block_id": "block-3", "columns": 2, '
        '"alignments": ["default", "center"], '
        '"header": [{"cell_id": "c0", "text": "层"}, '
        '{"cell_id": "c1", "text": "文件"}], '
        '"rows": [[{"cell_id": "c2", "text": "基座"}, '
        '{"cell_id": "c3", "text": "‰0‰"}]]}',
      );
    final runningA = module.runJob(jobA.jobId);
    await Future<void>.delayed(Duration.zero);
    expect(dao.getJob(jobA.jobId)!.status, TranslationJobStatus.running);

    // Job B's delivery (WorkManager may run both works at once) defers
    // without touching B's state — B stays queued for its next delivery.
    final resultB = await module.runJob(jobB.jobId);
    expect(resultB, TranslationRunResult.deferredBusy);
    expect(dao.getJob(jobB.jobId)!.status, TranslationJobStatus.queued);

    // A finishes, releasing the slot.
    gate.complete('["标题译文"]');
    await runningA;
    expect(dao.getJob(jobA.jobId)!.status, TranslationJobStatus.completed);

    // B's next delivery proceeds.
    queueValidReplies();
    expect(await module.runJob(jobB.jobId), TranslationRunResult.ran);
    expect(dao.getJob(jobB.jobId)!.status, TranslationJobStatus.completed);
  });
}

/// Throws an exception no runJob catch clause classifies — the fallback path.
class _ExplodingClient implements LlmCompletionClient {
  @override
  Future<LlmCompletion> complete({
    required String model,
    required List<LlmMessage> messages,
    required String thinkingMode,
    required String reasoningEffort,
    required Duration timeout,
  }) async => throw ArgumentError('corrupt internal state');

  @override
  Future<List<String>> listModels({required Duration timeout}) async => [];
}
