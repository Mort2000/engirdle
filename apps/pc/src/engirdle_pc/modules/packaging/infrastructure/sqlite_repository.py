from __future__ import annotations

from pathlib import Path

from engirdle_pc.modules.packaging.domain.models import PackageArtifact
from engirdle_pc.shared.infrastructure.database.connection import Database


class ArtifactRepository:
    def __init__(self, database: Database) -> None:
        self._database = database

    def next_artifact_revision(self, article_id: str, revision: int) -> int:
        with self._database.connect() as connection:
            row = connection.execute(
                """
                SELECT COALESCE(MAX(artifact_revision), 0) + 1 AS next_revision
                FROM package_artifacts WHERE article_id = ? AND revision = ?
                """,
                (article_id, revision),
            ).fetchone()
            assert row is not None
            return int(row["next_revision"])

    def insert(self, artifact: PackageArtifact) -> None:
        with self._database.connect() as connection:
            connection.execute(
                """
                INSERT INTO package_artifacts(
                    package_id, article_id, revision, artifact_revision, job_id,
                    opaque_name, path, size, sha256, state, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    artifact.package_id,
                    artifact.article_id,
                    artifact.revision,
                    artifact.artifact_revision,
                    artifact.job_id,
                    artifact.opaque_name,
                    str(artifact.path),
                    artifact.size,
                    artifact.sha256,
                    artifact.state,
                    artifact.created_at,
                ),
            )

    def get(self, package_id: str) -> PackageArtifact:
        with self._database.connect() as connection:
            row = connection.execute(
                "SELECT * FROM package_artifacts WHERE package_id = ?", (package_id,)
            ).fetchone()
            if row is None:
                raise KeyError(f"package {package_id} not found")
            return _map_artifact(row)

    def list_for_article(self, article_id: str) -> tuple[PackageArtifact, ...]:
        with self._database.connect() as connection:
            rows = connection.execute(
                "SELECT * FROM package_artifacts WHERE article_id = ?",
                (article_id,),
            ).fetchall()
            return tuple(_map_artifact(row) for row in rows)

    def delete_for_article(self, article_id: str) -> None:
        with self._database.connect() as connection:
            connection.execute(
                "DELETE FROM package_artifacts WHERE article_id = ?", (article_id,)
            )


def _map_artifact(row: object) -> PackageArtifact:
    return PackageArtifact(
        package_id=row["package_id"],  # type: ignore[index]
        article_id=row["article_id"],  # type: ignore[index]
        revision=row["revision"],  # type: ignore[index]
        artifact_revision=row["artifact_revision"],  # type: ignore[index]
        job_id=row["job_id"],  # type: ignore[index]
        opaque_name=row["opaque_name"],  # type: ignore[index]
        path=Path(row["path"]),  # type: ignore[index]
        size=row["size"],  # type: ignore[index]
        sha256=row["sha256"],  # type: ignore[index]
        state=row["state"],  # type: ignore[index]
        created_at=row["created_at"],  # type: ignore[index]
    )
