import 'dart:async';

import '../features/attribution/application/attribution_service.dart';
import '../features/catalog/application/catalog_service.dart';
import '../features/connection/application/connection_service.dart';
import '../features/connection/infrastructure/service_config_dao.dart';
import '../features/dictionary/application/dictionary_service.dart';
import '../features/dictionary/infrastructure/dictionary_dao.dart';
import '../features/importer/application/import_service.dart';
import '../features/importer/application/content_import_service.dart';
import '../features/importer/infrastructure/import_log_dao.dart';
import '../features/importer/infrastructure/source_import_dao.dart';
import '../features/library/application/library_service.dart';
import '../features/library/infrastructure/library_dao.dart';
import '../features/playback/application/audio_focus_port.dart';
import '../features/playback/application/playback_controller.dart';
import '../features/playback/application/playback_driver.dart';
import '../features/playback/domain/lease_registry.dart';
import '../features/playback/domain/playback_source_port.dart';
import '../features/playback/infrastructure/just_audio_driver.dart';
import '../features/playback/infrastructure/library_playback_source_adapter.dart';
import '../features/preferences/application/preferences_service.dart';
import '../features/preferences/infrastructure/preferences_dao.dart';
import '../features/translation/application/llm_client.dart';
import '../features/translation/application/secret_store.dart';
import '../features/translation/application/translation_module.dart';
import '../features/translation/application/translation_scheduler.dart';
import '../features/translation/application/translation_settings_service.dart';
import '../features/translation/infrastructure/deepseek_adapter.dart';
import '../features/translation/infrastructure/in_process_scheduler.dart';
import '../features/translation/infrastructure/keystore_secret_store.dart';
import '../features/translation/infrastructure/translation_background.dart';
import '../features/translation/infrastructure/translation_dao.dart';
import '../features/translation/infrastructure/translation_notification_prompt.dart';
import '../features/translation/infrastructure/workmanager_enqueue.dart';
import '../features/translation/infrastructure/workmanager_scheduler.dart';
import '../features/vocabulary/application/vocabulary_service.dart';
import '../features/vocabulary/infrastructure/vocabulary_dao.dart';
import '../platform/database/app_database.dart';
import '../platform/filesystem/app_directories.dart';
import '../platform/http/lan_http_client.dart';
import '../platform/documents/document_picker.dart';
import '../platform/logging/app_logger.dart';
import '../platform/translation/local_text_translator.dart';

/// Composition root (module architecture §6.1): the single place where
/// adapters and services are wired. No feature builds global singletons.
class AppDependencies {
  AppDependencies._({
    required this.database,
    required this.directories,
    required this.httpClient,
    required this.connection,
    required this.catalog,
    required this.library,
    required this.importer,
    required this.contentImport,
    required this.documentPicker,
    required this.playback,
    required this.dictionary,
    required this.vocabulary,
    required this.preferences,
    required this.attribution,
    required this.localTextTranslator,
    required this.translation,
    required this.translationSettings,
    StreamSubscription<void>? translationExternalSync,
  }) : _translationExternalSync = translationExternalSync;

  final StreamSubscription<void>? _translationExternalSync;

  final AppDatabase database;
  final AppDirectories directories;
  final LanHttpClient httpClient;
  final ConnectionService connection;
  final CatalogService catalog;
  final LibraryService library;
  final ImportService importer;
  final ContentImportService contentImport;
  final DocumentPicker documentPicker;
  final PlaybackController playback;
  final DictionaryService dictionary;
  final VocabularyService vocabulary;
  final PreferencesService preferences;
  final AttributionService attribution;
  final LocalTextTranslator localTextTranslator;
  final TranslationModule translation;
  final TranslationSettingsService translationSettings;

  /// Best-effort notification permission prompt used by the queue flow
  /// (§9.3). Always the platform-silent default: it swallows unavailable
  /// channels, so tests and in-process execution never notice it.
  final TranslationNotificationPrompt translationNotificationPrompt =
      const TranslationNotificationPrompt();

  /// Builds the full graph. [driver], [sourcePort], [focusPort] and [httpClient]
  /// are injectable for tests; [database] lets tests use in-memory databases.
  /// [focusPort] is required because the real one (AudioSessionAdapter) touches
  /// the platform and must not be constructed inside `flutter test`.
  ///
  /// [translationBackgroundExecution] switches translation execution to
  /// WorkManager (design §9.2): jobs run on a background engine with its own
  /// database connection, so this engine also starts the cross-engine job
  /// observer to keep badges and the reader status bar live. Off (tests,
  /// in-process execution) everything runs through the serial in-process
  /// scheduler. [translationScheduler] overrides the adapter either way.
  static Future<AppDependencies> build({
    required AppDirectories directories,
    AppDatabase? database,
    PlaybackDriver? driver,
    PlaybackSourcePort? sourcePort,
    required AudioFocusPort focusPort,
    LanHttpClient? httpClient,
    LocalTextTranslator localTextTranslator =
        const MethodChannelLocalTextTranslator(),
    DocumentPicker documentPicker = const MethodChannelDocumentPicker(),
    ContentImportService? contentImport,
    TranslationSecretStore? translationSecrets,
    LlmCompletionClient? translationClient,
    TranslationScheduler? translationScheduler,
    bool translationBackgroundExecution = false,
  }) async {
    await directories.ensureBaseLayout();
    final db = database ?? AppDatabase.open(directories.databaseFile.path);
    final http = httpClient ?? LanHttpClient();

    // Shared in-process lease registry: pins the active session's audio so
    // upgrade cleanup and delete cannot remove a file the player still reads.
    final leaseRegistry = LeaseRegistry();

    final serviceConfigDao = ServiceConfigDao(db.db);
    final libraryDao = LibraryDao(db.db);
    final importLogDao = ImportLogDao(db.db);
    final sourceImportDao = SourceImportDao(db.db);
    final vocabularyDao = VocabularyDao(db.db);
    final dictionaryManifestDao = DictionaryManifestDao(db.db);
    final preferencesDao = PreferencesDao(db.db);
    final translationDao = TranslationDao(db.db);

    final connection = ConnectionService(
      dao: serviceConfigDao,
      httpClient: http,
    );
    final library = LibraryService(
      dao: libraryDao,
      directories: directories,
      playbackLeases: leaseRegistry,
      // Table ownership (design §11.1): packaged translation rows are the
      // translation module's; its DAO writes them inside the install
      // transaction through this seam.
      packagedTranslationInstaller: translationDao.installPackagedSetFor,
    );
    final resolvedContentImport =
        contentImport ??
        ContentImportService(
          dao: sourceImportDao,
          library: library,
          directories: directories,
        );
    final catalog = CatalogService(connection: connection, library: library);
    final importer = ImportService(
      logDao: importLogDao,
      library: library,
      httpClient: http,
      directories: directories,
      logger: const AppLogger('importer'),
    );
    final preferences = PreferencesService(dao: preferencesDao);
    final playback = PlaybackController(
      driver: driver ?? JustAudioDriver(),
      sourcePort:
          sourcePort ??
          LibraryPlaybackSourceAdapter(
            library: library,
            registry: leaseRegistry,
          ),
      focusPort: focusPort,
      settingsPort: preferences,
    );
    final dictionary = DictionaryService(
      manifestDao: dictionaryManifestDao,
      directories: directories,
    );
    final vocabulary = VocabularyService(dao: vocabularyDao);
    final attribution = AttributionService(
      library: library,
      dictionary: dictionary,
    );

    // Translation pipeline: the secret store and LLM client are injectable
    // so tests script them without touching the platform or the network.
    final secrets = translationSecrets ?? const KeystoreSecretStore();
    final llmClient =
        translationClient ?? DeepSeekMobileAdapter(secrets: secrets);
    final scheduler =
        translationScheduler ??
        (translationBackgroundExecution
            ? WorkManagerTranslationScheduler(
                enqueuer: const WorkmanagerOneOffWorkEnqueuer(),
                // Constraints come from the job's frozen config snapshot
                // (§8.4), not the live profile.
                configOf: (jobId) => translationDao.getJob(jobId)?.config,
                articleTitleOf: (jobId) =>
                    translationArticleTitleOf(translationDao, library, jobId),
              )
            : InProcessTranslationScheduler());
    final translation = TranslationModule(
      dao: translationDao,
      library: library,
      client: llmClient,
      secrets: secrets,
      scheduler: scheduler,
      // Pause/cancel from the UI engine clears the job's notifications
      // (§12.4); completion/failure summaries are the worker's job.
      onJobTerminated: translationBackgroundExecution
          ? (jobId) {
              unawaited(
                const NativeTranslationProgressReporter().dismiss(jobId: jobId),
              );
            }
          : null,
    );
    if (scheduler is InProcessTranslationScheduler) {
      scheduler.runner = translation.runJob;
    }
    StreamSubscription<void>? externalSync;
    if (translationBackgroundExecution) {
      translation.startExternalSync();
      // Any local transition (queue, pause, resume, retry) re-arms the
      // observer; it stops itself once no job is active.
      externalSync = translation.changes.listen(
        (_) => translation.startExternalSync(),
      );
    }
    final translationSettings = TranslationSettingsService(
      dao: translationDao,
      secrets: secrets,
      client: llmClient,
    );

    return AppDependencies._(
      database: db,
      documentPicker: documentPicker,
      directories: directories,
      httpClient: http,
      connection: connection,
      catalog: catalog,
      library: library,
      importer: importer,
      contentImport: resolvedContentImport,
      playback: playback,
      dictionary: dictionary,
      vocabulary: vocabulary,
      preferences: preferences,
      attribution: attribution,
      localTextTranslator: localTextTranslator,
      translation: translation,
      translationSettings: translationSettings,
      translationExternalSync: externalSync,
    );
  }

  /// Startup recovery for interrupted imports (design §8.2). Call once after
  /// build; failures here must not prevent the app from starting.
  Future<void> recoverImports() async {
    await importer.recoverUnfinished();
    await contentImport.recover();
    await dictionary.recover();
    await translation.recover();
  }

  Future<void> dispose() async {
    await playback.dispose();
    dictionary.dispose();
    translation.dispose();
    await _translationExternalSync?.cancel();
    library.dispose();
    database.close();
  }
}
