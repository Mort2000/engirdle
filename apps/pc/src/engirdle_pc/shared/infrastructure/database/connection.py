from __future__ import annotations

import hashlib
import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path


class Database:
    def __init__(self, path: Path) -> None:
        self.path = path

    def initialize(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as connection:
            connection.executescript(_SCHEMA)
            columns = {
                row["name"]
                for row in connection.execute(
                    "PRAGMA table_info(article_revisions)"
                ).fetchall()
            }
            if "normalized_sha256" not in columns:
                connection.execute(
                    """
                    ALTER TABLE article_revisions
                    ADD COLUMN normalized_sha256 TEXT NOT NULL DEFAULT ''
                    """
                )
            rows = connection.execute(
                """
                SELECT article_id, revision, normalized_text
                FROM article_revisions WHERE normalized_sha256 = ''
                """
            ).fetchall()
            connection.executemany(
                """
                UPDATE article_revisions SET normalized_sha256 = ?
                WHERE article_id = ? AND revision = ?
                """,
                [
                    (
                        hashlib.sha256(row["normalized_text"].encode("utf-8")).hexdigest(),
                        row["article_id"],
                        row["revision"],
                    )
                    for row in rows
                ],
            )

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.path, timeout=30)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA journal_mode = WAL")
        try:
            yield connection
            connection.commit()
        except BaseException:
            connection.rollback()
            raise
        finally:
            connection.close()


_SCHEMA = """
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

CREATE TABLE IF NOT EXISTS translations (
    job_id TEXT NOT NULL,
    sentence_id TEXT NOT NULL,
    generated_text TEXT NOT NULL,
    edited_text TEXT,
    adapter_name TEXT NOT NULL,
    PRIMARY KEY (job_id, sentence_id),
    FOREIGN KEY (job_id) REFERENCES build_jobs(job_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS sentence_audio (
    job_id TEXT NOT NULL,
    sentence_id TEXT NOT NULL,
    pcm_path TEXT NOT NULL,
    sample_rate_hz INTEGER NOT NULL,
    sample_count INTEGER NOT NULL,
    adapter_name TEXT NOT NULL,
    PRIMARY KEY (job_id, sentence_id),
    FOREIGN KEY (job_id) REFERENCES build_jobs(job_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS audio_timeline (
    job_id TEXT NOT NULL,
    sentence_id TEXT NOT NULL,
    start_sample INTEGER NOT NULL,
    end_sample INTEGER NOT NULL,
    start_ms INTEGER NOT NULL,
    end_ms INTEGER NOT NULL,
    PRIMARY KEY (job_id, sentence_id),
    FOREIGN KEY (job_id) REFERENCES build_jobs(job_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS audio_outputs (
    job_id TEXT PRIMARY KEY,
    path TEXT NOT NULL,
    sample_rate_hz INTEGER NOT NULL,
    channels INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL,
    encoder_version TEXT NOT NULL,
    FOREIGN KEY (job_id) REFERENCES build_jobs(job_id) ON DELETE CASCADE
);

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

CREATE TABLE IF NOT EXISTS published_articles (
    article_id TEXT PRIMARY KEY,
    package_id TEXT NOT NULL,
    published_at TEXT NOT NULL,
    FOREIGN KEY (package_id) REFERENCES package_artifacts(package_id)
);

CREATE TABLE IF NOT EXISTS system_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT OR IGNORE INTO system_metadata(key, value) VALUES ('catalog_version', '0');
"""
