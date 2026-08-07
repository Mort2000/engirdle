CREATE TABLE IF NOT EXISTS package_artifacts (
    package_id TEXT PRIMARY KEY,
    article_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    artifact_revision INTEGER NOT NULL,
    job_id TEXT NOT NULL,
    opaque_name TEXT NOT NULL UNIQUE,
    path TEXT NOT NULL,
    size INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    state TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE (article_id, revision, artifact_revision),
    FOREIGN KEY (job_id) REFERENCES build_jobs(job_id)
);
