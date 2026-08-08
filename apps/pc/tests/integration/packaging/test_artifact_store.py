from __future__ import annotations

from pathlib import Path

import pytest
from sqlalchemy.exc import IntegrityError

from engirdle_pc.modules.packaging.application.models import PackageArtifact
from engirdle_pc.modules.packaging.infrastructure.sqlalchemy_repository import (
    SqlAlchemyArtifactRepository,
)
from engirdle_pc.shared.infrastructure.database.connection import Database

ARTICLE_ID = "art-1"
JOB_ID = "job-1"
CREATED_AT = "2026-01-01T00:00:00Z"


def _build_artifact(
    *,
    package_id: str = "pkg-1",
    article_id: str = ARTICLE_ID,
    revision: int = 1,
    artifact_revision: int = 1,
    job_id: str = JOB_ID,
    opaque_name: str | None = None,
    state: str = "validated",
) -> PackageArtifact:
    return PackageArtifact(
        package_id=package_id,
        article_id=article_id,
        revision=revision,
        artifact_revision=artifact_revision,
        job_id=job_id,
        opaque_name=opaque_name or f"{package_id}.readpack",
        path=Path("/workspace/artifacts") / f"{package_id}.readpack",
        size=4096,
        sha256="0123456789abcdef",
        state=state,
        created_at=CREATED_AT,
    )


def _seed_build_job(database: Database, job_id: str = JOB_ID) -> None:
    """Insert the minimal FK chain (articles -> article_revisions -> build_jobs).

    ``package_artifacts.job_id`` references ``build_jobs``, and foreign keys are
    enforced, so a valid job row must exist before any artifact is inserted.
    """
    with database.connect() as connection:
        connection.execute(
            "INSERT INTO articles(article_id, created_at) VALUES (?, ?)",
            (ARTICLE_ID, CREATED_AT),
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
                ARTICLE_ID,
                1,
                "Title",
                "raw",
                "normalized",
                "CC-BY-4.0",
                "source-sha",
                "normalized-sha",
                "structure-sha",
                "approved",
                CREATED_AT,
            ),
        )
        connection.execute(
            """
            INSERT INTO build_jobs(
                job_id, article_id, revision, status, stage, config_json, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (job_id, ARTICLE_ID, 1, "review_required", "packaging", "{}", CREATED_AT),
        )


@pytest.fixture
def store(tmp_path: Path) -> SqlAlchemyArtifactRepository:
    database = Database(tmp_path / "app.db")
    database.initialize()
    _seed_build_job(database)
    return SqlAlchemyArtifactRepository(database)


def test_insert_and_get_round_trips_every_field(store: SqlAlchemyArtifactRepository) -> None:
    original = _build_artifact()

    store.insert(original)

    fetched = store.get(original.package_id)
    assert fetched == original
    assert isinstance(fetched.path, Path)  # path is reconstructed as Path, not str


def test_get_missing_package_raises_key_error(store: SqlAlchemyArtifactRepository) -> None:
    with pytest.raises(KeyError):
        store.get("does-not-exist")


def test_mark_published_requires_existing_package(store: SqlAlchemyArtifactRepository) -> None:
    with pytest.raises(KeyError):
        store.mark_published("missing-package")


def test_mark_published_transitions_state(store: SqlAlchemyArtifactRepository) -> None:
    artifact = _build_artifact()
    store.insert(artifact)

    store.mark_published(artifact.package_id)

    assert store.get(artifact.package_id).state == "published"


def test_next_artifact_revision_starts_at_one_and_increments(
    store: SqlAlchemyArtifactRepository,
) -> None:
    assert store.next_artifact_revision(ARTICLE_ID, 1) == 1

    store.insert(_build_artifact(artifact_revision=1))

    assert store.next_artifact_revision(ARTICLE_ID, 1) == 2


def test_next_artifact_revision_is_scoped_per_article_and_revision(
    store: SqlAlchemyArtifactRepository,
) -> None:
    store.insert(_build_artifact(artifact_revision=1))

    # A different (article_id, revision) is independent of the seeded counter.
    assert store.next_artifact_revision("art-1", 99) == 1


def test_list_for_article_returns_only_matching_artifacts(
    store: SqlAlchemyArtifactRepository,
) -> None:
    first = _build_artifact(package_id="pkg-1", artifact_revision=1)
    second = _build_artifact(package_id="pkg-2", artifact_revision=2)
    other = _build_artifact(
        package_id="pkg-9", article_id="art-9", artifact_revision=1
    )
    for artifact in (first, second, other):
        store.insert(artifact)

    listed = store.list_for_article(ARTICLE_ID)

    assert {artifact.package_id for artifact in listed} == {"pkg-1", "pkg-2"}


def test_delete_for_article_removes_matching_rows_and_is_silent_when_empty(
    store: SqlAlchemyArtifactRepository,
) -> None:
    store.insert(_build_artifact(package_id="pkg-1", artifact_revision=1))
    store.insert(_build_artifact(package_id="pkg-2", artifact_revision=2))

    store.delete_for_article(ARTICLE_ID)  # removes both
    store.delete_for_article(ARTICLE_ID)  # already empty — must not raise

    assert store.list_for_article(ARTICLE_ID) == ()


def test_duplicate_opaque_name_violates_unique_constraint(
    store: SqlAlchemyArtifactRepository,
) -> None:
    store.insert(_build_artifact(package_id="pkg-1", opaque_name="shared.readpack"))

    with pytest.raises(IntegrityError):
        store.insert(
            _build_artifact(
                package_id="pkg-2",
                artifact_revision=2,
                opaque_name="shared.readpack",
            )
        )


def test_duplicate_composite_key_violates_unique_constraint(
    store: SqlAlchemyArtifactRepository,
) -> None:
    store.insert(
        _build_artifact(package_id="pkg-1", artifact_revision=1, opaque_name="a.readpack")
    )

    with pytest.raises(IntegrityError):
        store.insert(
            _build_artifact(
                package_id="pkg-2",  # different PK and opaque_name,
                artifact_revision=1,  # but same (article_id, revision, artifact_revision)
                opaque_name="b.readpack",
            )
        )
