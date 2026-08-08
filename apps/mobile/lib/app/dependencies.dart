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
import '../features/playback/application/playback_controller.dart';
import '../features/playback/application/playback_engine.dart';
import '../features/playback/infrastructure/just_audio_engine.dart';
import '../features/preferences/application/preferences_service.dart';
import '../features/preferences/infrastructure/preferences_dao.dart';
import '../features/vocabulary/application/vocabulary_service.dart';
import '../features/vocabulary/infrastructure/vocabulary_dao.dart';
import '../platform/database/app_database.dart';
import '../platform/filesystem/app_directories.dart';
import '../platform/http/lan_http_client.dart';
import '../platform/logging/app_logger.dart';

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

  /// Builds the full graph. [engine] and [httpClient] are injectable for
  /// tests; [openDatabase] lets tests use in-memory databases.
  static Future<AppDependencies> build({
    required AppDirectories directories,
    AppDatabase? database,
    PlaybackEngine? engine,
    LanHttpClient? httpClient,
  }) async {
    await directories.ensureBaseLayout();
    final db = database ?? AppDatabase.open(directories.databaseFile.path);
    final http = httpClient ?? LanHttpClient();

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
    final library = LibraryService(dao: libraryDao, directories: directories);
    final catalog = CatalogService(connection: connection, library: library);
    final importer = ImportService(
      logDao: importLogDao,
      library: library,
      httpClient: http,
      directories: directories,
      logger: const AppLogger('importer'),
    );
    final playback = PlaybackController(engine: engine ?? JustAudioEngine());
    final dictionary = DictionaryService(manifestDao: dictionaryManifestDao);
    final vocabulary = VocabularyService(dao: vocabularyDao);
    final preferences = PreferencesService(dao: preferencesDao);
    final attribution =
        AttributionService(library: library, dictionary: dictionary);

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
    );
  }

  /// Startup recovery for interrupted imports (design §8.2). Call once after
  /// build; failures here must not prevent the app from starting.
  Future<void> recoverImports() => importer.recoverUnfinished();

  Future<void> dispose() async {
    await playback.dispose();
    dictionary.dispose();
    database.close();
  }
}
