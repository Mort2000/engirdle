import 'package:sqlite3/sqlite3.dart';

/// Ordered migration chain. `kMigrations[i]` upgrades version i → i+1.
/// Table ownership (module architecture §6.5):
///   connection   → service_config
///   importer     → import_operations
///   library      → articles, blocks, sentences, article_reading_mode
///   vocabulary   → vocabulary
///   dictionary   → dictionary_manifest (the dictionary DB itself is separate)
///   preferences  → preferences
const kMigrations = <List<String>>[
  // v0 → v1
  [
    '''
    CREATE TABLE service_config (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      base_url TEXT,
      verified_at TEXT,
      last_catalog_check_at TEXT,
      updated_at TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE articles (
      article_id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      author TEXT,
      source_display_name TEXT,
      source_url TEXT,
      revision INTEGER NOT NULL,
      artifact_revision INTEGER NOT NULL,
      package_id TEXT NOT NULL,
      format_version TEXT NOT NULL,
      duration_ms INTEGER NOT NULL,
      audio_codec TEXT NOT NULL,
      sample_rate_hz INTEGER NOT NULL,
      channels INTEGER NOT NULL,
      size_bytes INTEGER NOT NULL,
      sha256 TEXT NOT NULL,
      installed_at TEXT NOT NULL,
      manifest_json TEXT NOT NULL,
      attribution_json TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE blocks (
      article_id TEXT NOT NULL REFERENCES articles(article_id) ON DELETE CASCADE,
      block_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      ord INTEGER NOT NULL,
      PRIMARY KEY (article_id, block_id)
    )
    ''',
    '''
    CREATE TABLE sentences (
      article_id TEXT NOT NULL,
      block_id TEXT NOT NULL,
      sentence_id TEXT NOT NULL,
      ord INTEGER NOT NULL,
      text TEXT NOT NULL,
      translation_zh TEXT,
      audio_start_ms INTEGER,
      audio_end_ms INTEGER,
      audio_start_sample INTEGER,
      audio_end_sample INTEGER,
      PRIMARY KEY (article_id, sentence_id),
      FOREIGN KEY (article_id, block_id)
        REFERENCES blocks(article_id, block_id) ON DELETE CASCADE
    )
    ''',
    'CREATE INDEX idx_sentences_article ON sentences(article_id, ord)',
    '''
    CREATE TABLE article_reading_mode (
      article_id TEXT PRIMARY KEY REFERENCES articles(article_id) ON DELETE CASCADE,
      mode TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE vocabulary (
      vocabulary_id TEXT PRIMARY KEY,
      surface TEXT NOT NULL,
      normalized TEXT NOT NULL,
      lemma TEXT,
      part_of_speech TEXT,
      sense_id TEXT NOT NULL,
      sense_en TEXT NOT NULL,
      sense_zh TEXT,
      source_name TEXT NOT NULL,
      dictionary_id TEXT NOT NULL,
      dictionary_revision INTEGER NOT NULL,
      article_id TEXT NOT NULL,
      revision INTEGER NOT NULL,
      sentence_id TEXT NOT NULL,
      sentence_text TEXT NOT NULL,
      sentence_translation_zh TEXT,
      article_title TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
    ''',
    'CREATE INDEX idx_vocabulary_created ON vocabulary(created_at DESC)',
    '''
    CREATE TABLE import_operations (
      import_id TEXT PRIMARY KEY,
      article_id TEXT NOT NULL,
      revision INTEGER NOT NULL,
      artifact_revision INTEGER NOT NULL,
      title TEXT NOT NULL,
      package_url TEXT NOT NULL,
      expected_size INTEGER NOT NULL,
      expected_sha256 TEXT NOT NULL,
      state TEXT NOT NULL,
      staging_path TEXT NOT NULL,
      error_kind TEXT,
      error_detail TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE dictionary_manifest (
      dictionary_id TEXT PRIMARY KEY,
      revision INTEGER NOT NULL,
      path TEXT NOT NULL,
      size_bytes INTEGER NOT NULL,
      sha256 TEXT NOT NULL,
      meta_json TEXT NOT NULL,
      installed_at TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE preferences (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
    ''',
  ],
  // v1 → v2: immutable dictionary installation records plus an explicit
  // active pointer. The legacy newest-installed-at inference is intentionally
  // removed; old rows are preserved and the previous newest row is activated.
  [
    'ALTER TABLE dictionary_manifest RENAME TO dictionary_manifest_legacy',
    '''
    CREATE TABLE dictionary_manifest (
      dictionary_id TEXT NOT NULL,
      revision INTEGER NOT NULL,
      path TEXT NOT NULL,
      package_size_bytes INTEGER NOT NULL,
      package_sha256 TEXT NOT NULL,
      manifest_json TEXT NOT NULL,
      installed_at TEXT NOT NULL,
      PRIMARY KEY (dictionary_id, revision)
    )
    ''',
    '''
    INSERT INTO dictionary_manifest (
      dictionary_id, revision, path, package_size_bytes, package_sha256,
      manifest_json, installed_at
    )
    SELECT dictionary_id, revision, path, size_bytes, sha256, meta_json, installed_at
    FROM dictionary_manifest_legacy
    ''',
    '''
    CREATE TABLE dictionary_active (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      dictionary_id TEXT NOT NULL,
      revision INTEGER NOT NULL,
      FOREIGN KEY (dictionary_id, revision)
        REFERENCES dictionary_manifest(dictionary_id, revision)
    )
    ''',
    '''
    INSERT INTO dictionary_active (id, dictionary_id, revision)
    SELECT 1, dictionary_id, revision
    FROM dictionary_manifest_legacy
    ORDER BY installed_at DESC
    LIMIT 1
    ''',
    'DROP TABLE dictionary_manifest_legacy',
  ],
];

/// Applies pending migrations inside a single transaction.
void migrate(Database db) {
  var version = db.userVersion;
  while (version < kMigrations.length) {
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final statement in kMigrations[version]) {
        db.execute(statement);
      }
      db.userVersion = version + 1;
      db.execute('COMMIT');
      version += 1;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}
