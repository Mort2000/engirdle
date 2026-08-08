from __future__ import annotations

from typing import Any, cast

from sqlalchemy import Integer, delete, select, update
from sqlalchemy import cast as sa_cast
from sqlalchemy.dialects.sqlite import insert
from sqlalchemy.engine import CursorResult
from sqlalchemy.orm import Session

from engirdle_pc.modules.publishing.domain.models import PublishedPackage
from engirdle_pc.modules.publishing.infrastructure.orm import (
    PublishedArticleRecord,
    SystemMetadataRecord,
)
from engirdle_pc.shared.infrastructure.database.connection import Database

_CATALOG_VERSION = "catalog_version"


def _upsert_published_stmt(package: PublishedPackage) -> Any:
    """Build the ``ON CONFLICT(article_id) DO UPDATE`` upsert used by both
    ``publish`` and ``restore`` — every column is overwritten from ``excluded``."""
    stmt = insert(PublishedArticleRecord).values(
        article_id=package.article_id,
        package_id=package.package_id,
        revision=package.revision,
        artifact_revision=package.artifact_revision,
        title=package.title,
        opaque_name=package.opaque_name,
        size=package.size,
        sha256=package.sha256,
        published_at=package.published_at,
    )
    return stmt.on_conflict_do_update(
        index_elements=["article_id"],
        set_={
            "package_id": stmt.excluded.package_id,
            "revision": stmt.excluded.revision,
            "artifact_revision": stmt.excluded.artifact_revision,
            "title": stmt.excluded.title,
            "opaque_name": stmt.excluded.opaque_name,
            "size": stmt.excluded.size,
            "sha256": stmt.excluded.sha256,
            "published_at": stmt.excluded.published_at,
        },
    )


def _bump_counter_stmt() -> Any:
    """``value = CAST(value AS INTEGER) + 1`` for the catalog_version row."""
    return (
        update(SystemMetadataRecord)
        .where(SystemMetadataRecord.key == _CATALOG_VERSION)
        .values(value=sa_cast(SystemMetadataRecord.value, Integer) + 1)
    )


def _read_counter(session: Session) -> str:
    value = session.scalar(
        select(SystemMetadataRecord.value).where(
            SystemMetadataRecord.key == _CATALOG_VERSION
        )
    )
    assert value is not None
    return str(value)


class SqlAlchemyPublishingRepository:
    """SQLAlchemy 2.0 implementation of the ``PublishingStore`` protocol.

    ``publish``/``restore``/``unpublish`` each run as one atomic session
    (upsert/delete + counter mutation + read-back), mirroring the original
    single-``connect()`` transaction.
    """

    def __init__(self, database: Database) -> None:
        self._database = database

    def publish(self, package: PublishedPackage) -> int:
        with self._database.sessions() as session, session.begin():
            session.execute(_upsert_published_stmt(package))
            session.execute(_bump_counter_stmt())
            return int(_read_counter(session))

    def restore(
        self,
        article_id: str,
        previous: PublishedPackage | None,
        catalog_version: int,
    ) -> None:
        with self._database.sessions() as session, session.begin():
            if previous is None:
                session.execute(
                    delete(PublishedArticleRecord).where(
                        PublishedArticleRecord.article_id == article_id
                    )
                )
            else:
                session.execute(_upsert_published_stmt(previous))
            session.execute(
                update(SystemMetadataRecord)
                .where(SystemMetadataRecord.key == _CATALOG_VERSION)
                .values(value=str(catalog_version))
            )

    def current_for_article(self, article_id: str) -> PublishedPackage | None:
        with self._database.sessions() as session, session.begin():
            record = session.get(PublishedArticleRecord, article_id)
            return record.to_dataclass() if record is not None else None

    def catalog_version(self) -> int:
        with self._database.sessions() as session, session.begin():
            return int(_read_counter(session))

    def unpublish(self, article_id: str) -> int:
        with self._database.sessions() as session, session.begin():
            deleted = cast(
                "CursorResult[Any]",
                session.execute(
                    delete(PublishedArticleRecord).where(
                        PublishedArticleRecord.article_id == article_id
                    )
                ),
            ).rowcount
            if deleted:
                session.execute(_bump_counter_stmt())
            return max(1, int(_read_counter(session)))

    def list_current(self) -> tuple[PublishedPackage, ...]:
        with self._database.sessions() as session, session.begin():
            records = session.scalars(
                select(PublishedArticleRecord).order_by(
                    PublishedArticleRecord.title.collate("NOCASE"),
                    PublishedArticleRecord.article_id,
                )
            )
            return tuple(record.to_dataclass() for record in records)
