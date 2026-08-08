"""baseline: import the legacy SQL-file schema verbatim.

Revision ID: 0001_baseline
Revises:
Create Date: 2026-08-08

This one-time baseline reproduces the exact schema previously created by the
seven legacy ``migrations/*.sql`` files (applied in order), so existing databases
stamp to head with no structural change. Future schema changes are authored as
normal Alembic revisions, not new ``.sql`` files.
"""
from __future__ import annotations

from alembic import op

# revision identifiers, used by Alembic.
revision = "0001_baseline"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 0001_content_initial
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS articles (
            article_id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL
        )
        """
    )
    op.execute(
        """
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
        )
        """
    )
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS content_blocks (
            article_id TEXT NOT NULL,
            revision INTEGER NOT NULL,
            block_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            block_order INTEGER NOT NULL,
            PRIMARY KEY (article_id, revision, block_id),
            FOREIGN KEY (article_id, revision)
                REFERENCES article_revisions(article_id, revision) ON DELETE CASCADE
        )
        """
    )
    op.execute(
        """
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
        )
        """
    )
    # 0002_production_initial
    op.execute(
        """
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
        )
        """
    )
    # 0003_translation_initial
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS translations (
            job_id TEXT NOT NULL,
            sentence_id TEXT NOT NULL,
            generated_text TEXT NOT NULL,
            edited_text TEXT,
            adapter_name TEXT NOT NULL,
            PRIMARY KEY (job_id, sentence_id),
            FOREIGN KEY (job_id) REFERENCES build_jobs(job_id) ON DELETE CASCADE
        )
        """
    )
    # 0004_speech_initial
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS sentence_audio (
            job_id TEXT NOT NULL,
            sentence_id TEXT NOT NULL,
            pcm_path TEXT NOT NULL,
            sample_rate_hz INTEGER NOT NULL,
            sample_count INTEGER NOT NULL,
            adapter_name TEXT NOT NULL,
            PRIMARY KEY (job_id, sentence_id),
            FOREIGN KEY (job_id) REFERENCES build_jobs(job_id) ON DELETE CASCADE
        )
        """
    )
    # 0005_audio_initial
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS audio_timeline (
            job_id TEXT NOT NULL,
            sentence_id TEXT NOT NULL,
            start_sample INTEGER NOT NULL,
            end_sample INTEGER NOT NULL,
            start_ms INTEGER NOT NULL,
            end_ms INTEGER NOT NULL,
            PRIMARY KEY (job_id, sentence_id),
            FOREIGN KEY (job_id) REFERENCES build_jobs(job_id) ON DELETE CASCADE
        )
        """
    )
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS audio_outputs (
            job_id TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            sample_rate_hz INTEGER NOT NULL,
            channels INTEGER NOT NULL,
            duration_ms INTEGER NOT NULL,
            encoder_version TEXT NOT NULL,
            FOREIGN KEY (job_id) REFERENCES build_jobs(job_id) ON DELETE CASCADE
        )
        """
    )
    # 0006_packaging_initial
    op.execute(
        """
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
        )
        """
    )
    # 0007_publishing_initial
    op.execute(
        """
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
        )
        """
    )
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS system_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """
    )
    op.execute(
        "INSERT OR IGNORE INTO system_metadata(key, value) VALUES ('catalog_version', '0')"
    )


def downgrade() -> None:
    # Baseline represents the full initial schema; downgrade returns to an empty DB.
    for table in (
        "system_metadata",
        "published_articles",
        "package_artifacts",
        "audio_outputs",
        "audio_timeline",
        "sentence_audio",
        "translations",
        "build_jobs",
        "content_sentences",
        "content_blocks",
        "article_revisions",
        "articles",
    ):
        op.execute(f"DROP TABLE IF EXISTS {table}")
