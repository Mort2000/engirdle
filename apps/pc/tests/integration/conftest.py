"""Shared fixtures for integration tests.

``database`` builds an initialized ``Database`` against a per-test tmp file.
``seed_article`` returns a callable that inserts the minimal ``articles`` +
``article_revisions`` rows, so ``build_jobs`` / ``package_artifacts`` FK targets
exist for module tests that need them.
"""
from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

import pytest

from engirdle_pc.shared.infrastructure.database.connection import Database

ARTICLE_ID = "art-1"
REVISION = 1
CREATED_AT = "2026-01-01T00:00:00Z"


@pytest.fixture
def database(tmp_path: Path) -> Database:
    db = Database(tmp_path / "app.db")
    db.initialize()
    return db


@pytest.fixture
def seed_article(database: Database) -> Callable[..., None]:
    def _seed(
        article_id: str = ARTICLE_ID,
        revision: int = REVISION,
        created_at: str = CREATED_AT,
    ) -> None:
        with database.connect() as connection:
            connection.execute(
                "INSERT INTO articles(article_id, created_at) VALUES (?, ?)",
                (article_id, created_at),
            )
            connection.execute(
                """
                INSERT INTO article_revisions(
                    article_id, revision, title, raw_text, normalized_text,
                    license_name, source_sha256, normalized_sha256, structure_sha256,
                    status, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    article_id,
                    revision,
                    "Title",
                    "raw",
                    "normalized",
                    "CC-BY-4.0",
                    "source-sha",
                    "normalized-sha",
                    "structure-sha",
                    "approved",
                    created_at,
                ),
            )

    return _seed


@pytest.fixture
def seed_build_job(database: Database, seed_article) -> Callable[..., None]:
    """Seed the full ``articles`` -> ``article_revisions`` -> ``build_jobs`` chain
    so tables that FK to ``build_jobs`` (translations/sentence_audio/audio_*/
    package_artifacts) can be populated."""

    def _seed(
        job_id: str = "job-1",
        article_id: str = ARTICLE_ID,
        revision: int = REVISION,
        created_at: str = CREATED_AT,
    ) -> None:
        seed_article(article_id, revision, created_at)
        with database.connect() as connection:
            connection.execute(
                """
                INSERT INTO build_jobs(
                    job_id, article_id, revision, status, stage, config_json, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (job_id, article_id, revision, "running", "translation", "{}", created_at),
            )

    return _seed
