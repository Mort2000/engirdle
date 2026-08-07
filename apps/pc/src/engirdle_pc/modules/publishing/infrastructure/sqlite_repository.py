from __future__ import annotations

from engirdle_pc.modules.publishing.domain.models import PublishedPackage
from engirdle_pc.shared.infrastructure.database.connection import Database


class PublishingRepository:
    def __init__(self, database: Database) -> None:
        self._database = database

    def publish(self, package: PublishedPackage) -> int:
        with self._database.connect() as connection:
            connection.execute(
                """
                INSERT INTO published_articles(
                    article_id, package_id, revision, artifact_revision, title,
                    opaque_name, size, sha256, published_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(article_id) DO UPDATE SET
                    package_id = excluded.package_id,
                    revision = excluded.revision,
                    artifact_revision = excluded.artifact_revision,
                    title = excluded.title,
                    opaque_name = excluded.opaque_name,
                    size = excluded.size,
                    sha256 = excluded.sha256,
                    published_at = excluded.published_at
                """,
                _package_values(package),
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

    def restore(
        self,
        article_id: str,
        previous: PublishedPackage | None,
        catalog_version: int,
    ) -> None:
        with self._database.connect() as connection:
            if previous is None:
                connection.execute(
                    "DELETE FROM published_articles WHERE article_id = ?",
                    (article_id,),
                )
            else:
                connection.execute(
                    """
                    INSERT INTO published_articles(
                        article_id, package_id, revision, artifact_revision, title,
                        opaque_name, size, sha256, published_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(article_id) DO UPDATE SET
                        package_id = excluded.package_id,
                        revision = excluded.revision,
                        artifact_revision = excluded.artifact_revision,
                        title = excluded.title,
                        opaque_name = excluded.opaque_name,
                        size = excluded.size,
                        sha256 = excluded.sha256,
                        published_at = excluded.published_at
                    """,
                    _package_values(previous),
                )
            connection.execute(
                "UPDATE system_metadata SET value = ? WHERE key = 'catalog_version'",
                (str(catalog_version),),
            )

    def current_for_article(self, article_id: str) -> PublishedPackage | None:
        with self._database.connect() as connection:
            row = connection.execute(
                "SELECT * FROM published_articles WHERE article_id = ?",
                (article_id,),
            ).fetchone()
            return _map_published(row) if row is not None else None

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
                SELECT * FROM published_articles
                ORDER BY title COLLATE NOCASE, article_id
                """
            ).fetchall()
            return tuple(_map_published(row) for row in rows)


def _package_values(package: PublishedPackage) -> tuple[object, ...]:
    return (
        package.article_id,
        package.package_id,
        package.revision,
        package.artifact_revision,
        package.title,
        package.opaque_name,
        package.size,
        package.sha256,
        package.published_at,
    )


def _map_published(row: object) -> PublishedPackage:
    return PublishedPackage(
        package_id=row["package_id"],  # type: ignore[index]
        article_id=row["article_id"],  # type: ignore[index]
        revision=row["revision"],  # type: ignore[index]
        artifact_revision=row["artifact_revision"],  # type: ignore[index]
        title=row["title"],  # type: ignore[index]
        opaque_name=row["opaque_name"],  # type: ignore[index]
        size=row["size"],  # type: ignore[index]
        sha256=row["sha256"],  # type: ignore[index]
        published_at=row["published_at"],  # type: ignore[index]
    )
