from __future__ import annotations

from pathlib import Path

from engirdle_pc.modules.packaging.public import PackageArtifact
from engirdle_pc.modules.publishing.domain.models import PublishedPackage
from engirdle_pc.shared.infrastructure.database.connection import Database


class PublishingRepository:
    def __init__(self, database: Database) -> None:
        self._database = database

    def publish(self, artifact: PackageArtifact, published_at: str) -> int:
        with self._database.connect() as connection:
            connection.execute(
                """
                INSERT INTO published_articles(article_id, package_id, published_at)
                VALUES (?, ?, ?)
                ON CONFLICT(article_id) DO UPDATE SET
                    package_id = excluded.package_id,
                    published_at = excluded.published_at
                """,
                (artifact.article_id, artifact.package_id, published_at),
            )
            connection.execute(
                "UPDATE package_artifacts SET state = 'published' WHERE package_id = ?",
                (artifact.package_id,),
            )
            connection.execute(
                """
                UPDATE system_metadata
                SET value = CAST(value AS INTEGER) + 1 WHERE key = 'catalog_version'
                """
            )
            row = connection.execute(
                "SELECT value FROM system_metadata WHERE key = 'catalog_version'"
            ).fetchone()
            assert row is not None
            return int(row["value"])

    def catalog_version(self) -> int:
        with self._database.connect() as connection:
            row = connection.execute(
                "SELECT value FROM system_metadata WHERE key = 'catalog_version'"
            ).fetchone()
            assert row is not None
            return int(row["value"])

    def unpublish(self, article_id: str) -> int:
        with self._database.connect() as connection:
            deleted = connection.execute(
                "DELETE FROM published_articles WHERE article_id = ?", (article_id,)
            ).rowcount
            if deleted:
                connection.execute(
                    """
                    UPDATE system_metadata SET value = CAST(value AS INTEGER) + 1
                    WHERE key = 'catalog_version'
                    """
                )
            row = connection.execute(
                "SELECT value FROM system_metadata WHERE key = 'catalog_version'"
            ).fetchone()
            assert row is not None
            return max(1, int(row["value"]))

    def list_current(self) -> tuple[PublishedPackage, ...]:
        with self._database.connect() as connection:
            rows = connection.execute(
                """
                SELECT artifacts.*, revisions.title
                FROM published_articles AS published
                JOIN package_artifacts AS artifacts USING(package_id)
                JOIN article_revisions AS revisions
                    ON revisions.article_id = artifacts.article_id
                    AND revisions.revision = artifacts.revision
                ORDER BY revisions.title COLLATE NOCASE, artifacts.article_id
                """
            ).fetchall()
            return tuple(
                PublishedPackage(
                    package_id=row["package_id"],
                    article_id=row["article_id"],
                    revision=row["revision"],
                    artifact_revision=row["artifact_revision"],
                    title=row["title"],
                    opaque_name=row["opaque_name"],
                    artifact_path=Path(row["path"]),
                    size=row["size"],
                    sha256=row["sha256"],
                )
                for row in rows
            )

    def resolve_published_name(self, opaque_name: str) -> PublishedPackage | None:
        with self._database.connect() as connection:
            row = connection.execute(
                """
                SELECT artifacts.*, revisions.title
                FROM published_articles AS published
                JOIN package_artifacts AS artifacts USING(package_id)
                JOIN article_revisions AS revisions
                    ON revisions.article_id = artifacts.article_id
                    AND revisions.revision = artifacts.revision
                WHERE artifacts.opaque_name = ?
                """,
                (opaque_name,),
            ).fetchone()
            if row is None:
                return None
            return PublishedPackage(
                package_id=row["package_id"],
                article_id=row["article_id"],
                revision=row["revision"],
                artifact_revision=row["artifact_revision"],
                title=row["title"],
                opaque_name=row["opaque_name"],
                artifact_path=Path(row["path"]),
                size=row["size"],
                sha256=row["sha256"],
            )
