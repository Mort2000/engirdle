CREATE TABLE IF NOT EXISTS published_articles (
    article_id TEXT PRIMARY KEY,
    package_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    artifact_revision INTEGER NOT NULL,
    title TEXT NOT NULL,
    opaque_name TEXT NOT NULL UNIQUE,
    size INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    published_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS system_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

INSERT OR IGNORE INTO system_metadata(key, value) VALUES ('catalog_version', '0');
