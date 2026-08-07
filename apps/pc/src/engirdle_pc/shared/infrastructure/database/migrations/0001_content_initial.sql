CREATE TABLE IF NOT EXISTS articles (
    article_id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS article_revisions (
    article_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    title TEXT NOT NULL,
    raw_text TEXT NOT NULL,
    normalized_text TEXT NOT NULL,
    author TEXT,
    source_name TEXT,
    source_url TEXT,
    license_name TEXT NOT NULL,
    source_sha256 TEXT NOT NULL,
    normalized_sha256 TEXT NOT NULL,
    structure_sha256 TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at TEXT NOT NULL,
    approved_at TEXT,
    published_at TEXT,
    PRIMARY KEY (article_id, revision),
    FOREIGN KEY (article_id) REFERENCES articles(article_id)
);

CREATE TABLE IF NOT EXISTS content_blocks (
    article_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    block_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    block_order INTEGER NOT NULL,
    PRIMARY KEY (article_id, revision, block_id),
    FOREIGN KEY (article_id, revision)
        REFERENCES article_revisions(article_id, revision) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS content_sentences (
    article_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    block_id TEXT NOT NULL,
    sentence_id TEXT NOT NULL,
    sentence_order INTEGER NOT NULL,
    text TEXT NOT NULL,
    PRIMARY KEY (article_id, revision, sentence_id),
    FOREIGN KEY (article_id, revision, block_id)
        REFERENCES content_blocks(article_id, revision, block_id) ON DELETE CASCADE
);
