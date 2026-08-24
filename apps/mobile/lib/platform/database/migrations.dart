import 'package:sqlite3/sqlite3.dart';

/// Ordered migration chain. `kMigrations[i]` upgrades version i → i+1.
/// Table ownership (module architecture §6.5):
///   connection   → service_config
///   importer     → import_operations
///   library      → articles, article_artifacts, blocks, sentences,
///                  article_reading_mode, article_active_translations,
///                  narration_assets, sentence_audio_ranges
///   translation  → translation_sets, sentence_translations,
///                  table_cell_translations
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
  // v2 → v3: Chinese-only dictionary senses must remain Chinese-only in
  // frozen vocabulary snapshots; sense_en is therefore nullable.
  [
    'ALTER TABLE vocabulary RENAME TO vocabulary_legacy',
    '''
    CREATE TABLE vocabulary (
      vocabulary_id TEXT PRIMARY KEY,
      surface TEXT NOT NULL,
      normalized TEXT NOT NULL,
      lemma TEXT,
      part_of_speech TEXT,
      sense_id TEXT NOT NULL,
      sense_en TEXT,
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
    '''
    INSERT INTO vocabulary (
      vocabulary_id, surface, normalized, lemma, part_of_speech, sense_id,
      sense_en, sense_zh, source_name, dictionary_id, dictionary_revision,
      article_id, revision, sentence_id, sentence_text,
      sentence_translation_zh, article_title, created_at
    )
    SELECT
      vocabulary_id, surface, normalized, lemma, part_of_speech, sense_id,
      sense_en, sense_zh, source_name, dictionary_id, dictionary_revision,
      article_id, revision, sentence_id, sentence_text,
      sentence_translation_zh, article_title, created_at
    FROM vocabulary_legacy
    ''',
    'DROP TABLE vocabulary_legacy',
    'CREATE INDEX idx_vocabulary_created ON vocabulary(created_at DESC)',
  ],
  // v3 → v4: readpack v1.1 markdown-blocks. Blocks gain a typed JSON payload
  // (heading level, list/quote styling, table cells, code body) and sentences
  // gain inline render runs. Both columns carry explicit defaults so legacy
  // rows keep validating: an empty payload decodes as a plain paragraph and
  // an empty render list as a single plain run.
  [
    "ALTER TABLE blocks ADD COLUMN payload_json TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE sentences ADD COLUMN render_json TEXT NOT NULL DEFAULT ''",
  ],
  // v4 → v5: base/derivative split (lightweight-readpack design §11). The
  // sentence/table base becomes immutable source-only structure; packaged
  // translations move into a complete active `translation_sets` family and
  // the audio columns into `narration_assets`/`sentence_audio_ranges`.
  // Legacy articles keep reading identically through the composed
  // projection. Pre-v5 installs never stored article hashes, so migrated
  // base rows carry NULL structure hashes; every derivative created after
  // v5 binds the exact structure hash. Child tables are rebuilt rather than
  // altered because SQLite renames rewrite foreign-key references: the
  // legacy tables are drained and dropped only after the new ones hold the
  // copied rows, so no cascade can lose data mid-migration.
  [
    'ALTER TABLE articles RENAME TO articles_legacy',
    'ALTER TABLE blocks RENAME TO blocks_legacy',
    'ALTER TABLE sentences RENAME TO sentences_legacy',
    'ALTER TABLE article_reading_mode RENAME TO article_reading_mode_legacy',
    '''
    CREATE TABLE articles (
      article_id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      author TEXT,
      source_display_name TEXT,
      source_url TEXT,
      revision INTEGER NOT NULL,
      origin TEXT NOT NULL DEFAULT 'catalog',
      source_sha256 TEXT,
      structure_sha256 TEXT,
      parser_version TEXT,
      segmenter_version TEXT,
      current_artifact_revision INTEGER NOT NULL,
      installed_at TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE article_artifacts (
      article_id TEXT NOT NULL REFERENCES articles(article_id) ON DELETE CASCADE,
      artifact_revision INTEGER NOT NULL,
      ingress_kind TEXT NOT NULL,
      package_id TEXT,
      format_version TEXT NOT NULL,
      size_bytes INTEGER NOT NULL,
      sha256 TEXT NOT NULL,
      manifest_json TEXT NOT NULL,
      attribution_json TEXT NOT NULL,
      installed_at TEXT NOT NULL,
      PRIMARY KEY (article_id, artifact_revision)
    )
    ''',
    '''
    CREATE TABLE blocks (
      article_id TEXT NOT NULL REFERENCES articles(article_id) ON DELETE CASCADE,
      block_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      ord INTEGER NOT NULL,
      payload_json TEXT NOT NULL DEFAULT '',
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
      render_json TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (article_id, sentence_id),
      FOREIGN KEY (article_id, block_id)
        REFERENCES blocks(article_id, block_id) ON DELETE CASCADE
    )
    ''',
    '''
    CREATE TABLE article_reading_mode (
      article_id TEXT PRIMARY KEY REFERENCES articles(article_id) ON DELETE CASCADE,
      mode TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    ''',
    r'''
    INSERT INTO articles (
      article_id, title, author, source_display_name, source_url, revision,
      origin, source_sha256, structure_sha256, parser_version,
      segmenter_version, current_artifact_revision, installed_at
    )
    SELECT
      article_id, title, author, source_display_name, source_url, revision,
      'catalog', NULL, NULL,
      json_extract(manifest_json, '$.pipeline.parser'),
      json_extract(manifest_json, '$.pipeline.segmenter'),
      artifact_revision, installed_at
    FROM articles_legacy
    ''',
    '''
    INSERT INTO article_artifacts (
      article_id, artifact_revision, ingress_kind, package_id, format_version,
      size_bytes, sha256, manifest_json, attribution_json, installed_at
    )
    SELECT
      article_id, artifact_revision, 'catalog', package_id, format_version,
      size_bytes, sha256, manifest_json, attribution_json, installed_at
    FROM articles_legacy
    ''',
    '''
    INSERT INTO blocks (article_id, block_id, kind, ord, payload_json)
    SELECT article_id, block_id, kind, ord, payload_json FROM blocks_legacy
    ''',
    '''
    INSERT INTO sentences (
      article_id, block_id, sentence_id, ord, text, render_json
    )
    SELECT
      article_id, block_id, sentence_id, ord, text, render_json
    FROM sentences_legacy
    ''',
    '''
    INSERT INTO article_reading_mode (article_id, mode, updated_at)
    SELECT article_id, mode, updated_at FROM article_reading_mode_legacy
    ''',
    '''
    CREATE TABLE translation_sets (
      translation_set_id TEXT PRIMARY KEY,
      article_id TEXT NOT NULL REFERENCES articles(article_id) ON DELETE CASCADE,
      artifact_revision INTEGER NOT NULL,
      structure_sha256 TEXT,
      target_locale TEXT NOT NULL,
      origin TEXT NOT NULL,
      status TEXT NOT NULL,
      pipeline_json TEXT,
      created_at TEXT NOT NULL
    )
    ''',
    // v1 packages always carry a full translation, so the packaged set exists
    // exactly when at least one sentence translation was installed.
    r'''
    INSERT INTO translation_sets (
      translation_set_id, article_id, artifact_revision, structure_sha256,
      target_locale, origin, status, pipeline_json, created_at
    )
    SELECT
      'translation-' || article_id || '-zh-Hans',
      article_id, artifact_revision, NULL,
      'zh-Hans', 'packaged', 'complete',
      json_object(
        'provider', json_extract(manifest_json, '$.pipeline.translation.provider'),
        'model', json_extract(manifest_json, '$.pipeline.translation.model'),
        'prompt', json_extract(manifest_json, '$.pipeline.translation.prompt'),
        'thinking', json_extract(manifest_json, '$.pipeline.translation.thinking'),
        'reasoning_effort',
          json_extract(manifest_json, '$.pipeline.translation.reasoning_effort')
      ),
      installed_at
    FROM articles_legacy a
    WHERE EXISTS (
      SELECT 1 FROM sentences_legacy s
      WHERE s.article_id = a.article_id AND s.translation_zh IS NOT NULL
    )
    ''',
    '''
    CREATE TABLE sentence_translations (
      translation_set_id TEXT NOT NULL
        REFERENCES translation_sets(translation_set_id) ON DELETE CASCADE,
      sentence_id TEXT NOT NULL,
      text TEXT NOT NULL,
      PRIMARY KEY (translation_set_id, sentence_id)
    )
    ''',
    '''
    INSERT INTO sentence_translations (translation_set_id, sentence_id, text)
    SELECT 'translation-' || s.article_id || '-zh-Hans', s.sentence_id,
           s.translation_zh
    FROM sentences_legacy s
    WHERE s.translation_zh IS NOT NULL
    ''',
    '''
    CREATE TABLE table_cell_translations (
      translation_set_id TEXT NOT NULL
        REFERENCES translation_sets(translation_set_id) ON DELETE CASCADE,
      block_id TEXT NOT NULL,
      cell_id TEXT NOT NULL,
      text TEXT NOT NULL,
      PRIMARY KEY (translation_set_id, block_id, cell_id)
    )
    ''',
    // Cell order is derived from the base table structure at read time, so
    // no ordinal column is stored here (coverage must match the base
    // exactly — an activation with drifted coverage is rejected in code).
    r'''
    INSERT INTO table_cell_translations (
      translation_set_id, block_id, cell_id, text
    )
    SELECT
      'translation-' || b.article_id || '-zh-Hans', b.block_id, je.key,
      je.value
    FROM blocks_legacy b, json_each(b.payload_json, '$.translation_zh') je
    WHERE b.kind = 'table'
      AND json_valid(b.payload_json)
      AND je.type = 'text'
    ''',
    '''
    CREATE TABLE article_active_translations (
      article_id TEXT NOT NULL
        REFERENCES articles(article_id) ON DELETE CASCADE,
      target_locale TEXT NOT NULL,
      translation_set_id TEXT NOT NULL
        REFERENCES translation_sets(translation_set_id),
      PRIMARY KEY (article_id, target_locale)
    )
    ''',
    '''
    INSERT INTO article_active_translations (
      article_id, target_locale, translation_set_id
    )
    SELECT article_id, 'zh-Hans', 'translation-' || article_id || '-zh-Hans'
    FROM articles_legacy a
    WHERE EXISTS (SELECT 1 FROM translation_sets t WHERE t.article_id = a.article_id)
    ''',
    '''
    CREATE TABLE narration_assets (
      narration_id TEXT PRIMARY KEY,
      article_id TEXT NOT NULL REFERENCES articles(article_id) ON DELETE CASCADE,
      artifact_revision INTEGER NOT NULL,
      structure_sha256 TEXT,
      audio_path TEXT NOT NULL,
      codec TEXT NOT NULL,
      sample_rate_hz INTEGER NOT NULL,
      channels INTEGER NOT NULL,
      duration_ms INTEGER NOT NULL
    )
    ''',
    '''
    INSERT INTO narration_assets (
      narration_id, article_id, artifact_revision, structure_sha256,
      audio_path, codec, sample_rate_hz, channels, duration_ms
    )
    SELECT
      'narration-' || article_id, article_id, artifact_revision, NULL,
      'audio/article.m4a', audio_codec, sample_rate_hz, channels, duration_ms
    FROM articles_legacy a
    WHERE EXISTS (
      SELECT 1 FROM sentences_legacy s
      WHERE s.article_id = a.article_id AND s.audio_start_ms IS NOT NULL
    )
    ''',
    '''
    CREATE TABLE sentence_audio_ranges (
      narration_id TEXT NOT NULL
        REFERENCES narration_assets(narration_id) ON DELETE CASCADE,
      sentence_id TEXT NOT NULL,
      audio_start_ms INTEGER NOT NULL,
      audio_end_ms INTEGER NOT NULL,
      audio_start_sample INTEGER NOT NULL,
      audio_end_sample INTEGER NOT NULL,
      PRIMARY KEY (narration_id, sentence_id)
    )
    ''',
    '''
    INSERT INTO sentence_audio_ranges (
      narration_id, sentence_id, audio_start_ms, audio_end_ms,
      audio_start_sample, audio_end_sample
    )
    SELECT
      'narration-' || s.article_id, s.sentence_id, s.audio_start_ms,
      s.audio_end_ms, s.audio_start_sample, s.audio_end_sample
    FROM sentences_legacy s
    WHERE s.audio_start_ms IS NOT NULL
    ''',
    // The table base payload keeps only source structure; translations live
    // in table_cell_translations from now on.
    r'''
    UPDATE blocks SET payload_json = json_remove(payload_json, '$.translation_zh')
    WHERE kind = 'table' AND json_valid(payload_json)
    ''',
    'DROP TABLE sentences_legacy',
    'DROP TABLE blocks_legacy',
    'DROP TABLE article_reading_mode_legacy',
    'DROP TABLE articles_legacy',
    // Recreated last: the legacy index followed sentences_legacy and only
    // disappears with that table.
    'CREATE INDEX idx_sentences_article ON sentences(article_id, ord)',
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
