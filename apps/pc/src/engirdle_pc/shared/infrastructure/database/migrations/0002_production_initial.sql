CREATE TABLE IF NOT EXISTS build_jobs (
    job_id TEXT PRIMARY KEY,
    article_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    status TEXT NOT NULL,
    stage TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    config_json TEXT NOT NULL,
    checkpoint_json TEXT,
    created_at TEXT NOT NULL,
    started_at TEXT,
    heartbeat_at TEXT,
    finished_at TEXT,
    error_code TEXT,
    error_message TEXT,
    FOREIGN KEY (article_id, revision)
        REFERENCES article_revisions(article_id, revision)
);
