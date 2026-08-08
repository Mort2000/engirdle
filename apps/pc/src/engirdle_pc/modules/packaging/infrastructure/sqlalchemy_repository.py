from __future__ import annotations

from typing import Any, cast

from sqlalchemy import delete, func, select, update
from sqlalchemy.engine import CursorResult

from engirdle_pc.modules.packaging.application.models import PackageArtifact
from engirdle_pc.modules.packaging.infrastructure.orm import PackageArtifactRecord
from engirdle_pc.shared.infrastructure.database.connection import Database


class SqlAlchemyArtifactRepository:
    """SQLAlchemy 2.0 implementation of the ``ArtifactStore`` protocol.

    Drop-in alternative to :class:`ArtifactRepository`; satisfies the same
    behavioural contract (KeyError on missing package, MAX()+1 revision
    counter). Each method runs in its own session/transaction, mirroring the
    per-method ``Database.connect()`` boundary of the raw-SQL repository.
    ``with session, session.begin():`` commits on a clean exit and rolls back on
    any exception — the same commit/rollback contract as ``Database.connect()``.
    """

    def __init__(self, database: Database) -> None:
        self._database = database

    def next_artifact_revision(self, article_id: str, revision: int) -> int:
        with self._database.sessions() as session, session.begin():
            value = session.scalar(
                select(
                    func.coalesce(
                        func.max(PackageArtifactRecord.artifact_revision), 0
                    )
                    + 1
                ).where(
                    PackageArtifactRecord.article_id == article_id,
                    PackageArtifactRecord.revision == revision,
                )
            )
            assert value is not None
            return int(value)

    def insert(self, artifact: PackageArtifact) -> None:
        with self._database.sessions() as session, session.begin():
            session.add(PackageArtifactRecord.from_dataclass(artifact))

    def get(self, package_id: str) -> PackageArtifact:
        with self._database.sessions() as session, session.begin():
            record = session.get(PackageArtifactRecord, package_id)
            if record is None:
                raise KeyError(f"package {package_id} not found")
            return record.to_dataclass()

    def list_for_article(self, article_id: str) -> tuple[PackageArtifact, ...]:
        with self._database.sessions() as session, session.begin():
            records = session.scalars(
                select(PackageArtifactRecord).where(
                    PackageArtifactRecord.article_id == article_id
                )
            )
            return tuple(record.to_dataclass() for record in records)

    def mark_published(self, package_id: str) -> None:
        with self._database.sessions() as session, session.begin():
            # session.execute() of an UPDATE returns CursorResult at runtime but is
            # typed as Result[Any]; cast to read rowcount. Kept as a single-statement
            # UPDATE + affected-row check to mirror the raw-SQL repository and to
            # exercise the bulk-update+rowcount idiom the production state machine
            # relies on.
            result = cast(
                "CursorResult[Any]",
                session.execute(
                    update(PackageArtifactRecord)
                    .where(PackageArtifactRecord.package_id == package_id)
                    .values(state="published")
                ),
            )
            if result.rowcount != 1:
                raise KeyError(f"package {package_id} not found")

    def delete_for_article(self, article_id: str) -> None:
        with self._database.sessions() as session, session.begin():
            session.execute(
                delete(PackageArtifactRecord).where(
                    PackageArtifactRecord.article_id == article_id
                )
            )
