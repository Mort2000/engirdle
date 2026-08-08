from __future__ import annotations

import sqlite3
from pathlib import Path

from engirdle_pc.shared.infrastructure.database.connection import Database

EXPECTED_TABLES = {
    "alembic_version",
    "articles",
    "article_revisions",
    "content_blocks",
    "content_sentences",
    "build_jobs",
    "translations",
    "sentence_audio",
    "audio_timeline",
    "audio_outputs",
    "package_artifacts",
    "published_articles",
    "system_metadata",
    "voice_anchor_batches",
    "voice_anchor_candidates",
    "voice_profiles",
}


def _tables(connection: sqlite3.Connection) -> set[str]:
    return {
        row["name"]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
    }


def _columns(connection: sqlite3.Connection, table: str) -> set[str]:
    return {
        row["name"]
        for row in connection.execute(f"PRAGMA table_info({table})").fetchall()
    }


def test_database_applies_migrations_idempotently(tmp_path: Path) -> None:
    database = Database(tmp_path / "app.db")

    database.initialize()
    database.initialize()  # second run must be a no-op (``alembic upgrade head``)

    with database.connect() as connection:
        assert _tables(connection) == EXPECTED_TABLES

        versions = [
            row["version_num"]
            for row in connection.execute(
                "SELECT version_num FROM alembic_version"
            ).fetchall()
        ]
        assert versions == ["0002_voice_profiles"]

        # Preserve the original schema contract: the published_articles and
        # package_artifacts column sets must be unchanged after the Alembic
        # takeover. This is the safety net for the hand-transcribed baseline.
        assert _columns(connection, "published_articles") == {
            "article_id",
            "package_id",
            "revision",
            "artifact_revision",
            "title",
            "opaque_name",
            "size",
            "sha256",
            "published_at",
        }
        assert _columns(connection, "package_artifacts") == {
            "package_id",
            "article_id",
            "revision",
            "artifact_revision",
            "job_id",
            "opaque_name",
            "path",
            "size",
            "sha256",
            "state",
            "created_at",
        }
