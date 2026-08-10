import '../features/attribution/application/attribution_service.dart';
import '../features/catalog/application/catalog_service.dart';
import '../features/connection/application/connection_service.dart';
import '../features/connection/infrastructure/service_config_dao.dart';
import '../features/dictionary/application/dictionary_service.dart';
import '../features/dictionary/infrastructure/dictionary_dao.dart';
import '../features/importer/application/import_service.dart';
import '../features/importer/infrastructure/import_log_dao.dart';
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
import '../features/vocabulary/application/vocabulary_service.dart';
import '../features/vocabulary/infrastructure/vocabulary_dao.dart';
import '../platform/database/app_database.dart';
import '../platform/filesystem/app_directories.dart';
import '../platform/http/lan_http_client.dart';
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
    required this.playback,
    required this.dictionary,
    required this.vocabulary,
    required this.preferences,
    required this.attribution,
    required this.localTextTranslator,
  });

  final AppDatabase database;
  final AppDirectories directories;
  final LanHttpClient httpClient;
  final ConnectionService connection;
  final CatalogService catalog;
  final LibraryService library;
  final ImportService importer;
  final PlaybackController playback;
  final DictionaryService dictionary;
  final VocabularyService vocabulary;
  final PreferencesService preferences;
  final AttributionService attribution;
  final LocalTextTranslator localTextTranslator;

  /// Builds the full graph. [driver], [sourcePort], [focusPort] and [httpClient]
  /// are injectable for tests; [database] lets tests use in-memory databases.
  /// [focusPort] is required because the real one (AudioSessionAdapter) touches
  /// the platform and must not be constructed inside `flutter test`.
  static Future<AppDependencies> build({
    required AppDirectories directories,
    AppDatabase? database,
    PlaybackDriver? driver,
    PlaybackSourcePort? sourcePort,
    required AudioFocusPort focusPort,
    LanHttpClient? httpClient,
    LocalTextTranslator localTextTranslator =
        const MethodChannelLocalTextTranslator(),
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
    final vocabularyDao = VocabularyDao(db.db);
    final dictionaryManifestDao = DictionaryManifestDao(db.db);
    final preferencesDao = PreferencesDao(db.db);

    final connection = ConnectionService(
      dao: serviceConfigDao,
      httpClient: http,
    );
    final library = LibraryService(
      dao: libraryDao,
      directories: directories,
      playbackLeases: leaseRegistry,
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

    return AppDependencies._(
      database: db,
      directories: directories,
      httpClient: http,
      connection: connection,
      catalog: catalog,
      library: library,
      importer: importer,
      playback: playback,
      dictionary: dictionary,
      vocabulary: vocabulary,
      preferences: preferences,
      attribution: attribution,
      localTextTranslator: localTextTranslator,
    );
  }

  /// Startup recovery for interrupted imports (design §8.2). Call once after
  /// build; failures here must not prevent the app from starting.
  Future<void> recoverImports() async {
    await importer.recoverUnfinished();
    await dictionary.recover();
  }

  Future<void> dispose() async {
    await playback.dispose();
    dictionary.dispose();
    database.close();
  }
}
