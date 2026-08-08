from __future__ import annotations

from datetime import timedelta
from typing import Any, cast

from sqlalchemy import delete, func, or_, select, text, update
from sqlalchemy.engine import CursorResult

from engirdle_pc.modules.production.domain.errors import InvalidJobState, JobNotFound
from engirdle_pc.modules.production.domain.models import (
    BuildJob,
    JobStatus,
    PipelineConfig,
    ProductionStage,
)
from engirdle_pc.modules.production.infrastructure.orm import BuildJobRecord
from engirdle_pc.shared.application.runtime import Clock, IdentifierGenerator
from engirdle_pc.shared.domain.time import isoformat_utc
from engirdle_pc.shared.infrastructure.database.connection import Database


class SqlAlchemyJobRepository:
    """SQLAlchemy 2.0 implementation of the ``JobStore`` protocol.

    ``claim_next`` is the one method that cannot use a plain ORM session: SQLite's
    DEFERRED begin (the session default) would let two workers both SELECT the
    same QUEUED row before either takes the write lock. It therefore runs on a
    Core connection with an explicit ``BEGIN IMMEDIATE`` to acquire the write
    lock before the SELECT, preserving the original atomic-lease semantics.
    """

    def __init__(
        self,
        database: Database,
        clock: Clock,
        identifiers: IdentifierGenerator,
    ) -> None:
        self._database = database
        self._clock = clock
        self._identifiers = identifiers

    def _now(self) -> str:
        return isoformat_utc(self._clock.now())

    def create(self, article_id: str, revision: int, config: PipelineConfig) -> BuildJob:
        job_id = self._identifiers.new()
        created_at = self._now()
        with self._database.sessions() as session, session.begin():
            session.add(
                BuildJobRecord(
                    job_id=job_id,
                    article_id=article_id,
                    revision=revision,
                    status=JobStatus.QUEUED.value,
                    stage=ProductionStage.QUEUED.value,
                    attempts=0,
                    config_json=config.to_json(),
                    created_at=created_at,
                )
            )
        return self.get(job_id)

    def get(self, job_id: str) -> BuildJob:
        with self._database.sessions() as session, session.begin():
            record = session.get(BuildJobRecord, job_id)
            if record is None:
                raise JobNotFound(f"job {job_id} not found")
            return record.to_dataclass()

    def list_recent(self, limit: int = 50) -> tuple[BuildJob, ...]:
        with self._database.sessions() as session, session.begin():
            records = session.scalars(
                select(BuildJobRecord)
                .order_by(BuildJobRecord.created_at.desc())
                .limit(limit)
            )
            return tuple(record.to_dataclass() for record in records)

    def list_ids_for_article(self, article_id: str) -> tuple[str, ...]:
        with self._database.sessions() as session, session.begin():
            return tuple(
                session.scalars(
                    select(BuildJobRecord.job_id).where(
                        BuildJobRecord.article_id == article_id
                    )
                )
            )

    def delete_for_article(self, article_id: str) -> None:
        with self._database.sessions() as session, session.begin():
            session.execute(
                delete(BuildJobRecord).where(BuildJobRecord.article_id == article_id)
            )

    def recover_stale(self, lease_seconds: int = 300) -> int:
        threshold = isoformat_utc(self._clock.now() - timedelta(seconds=lease_seconds))
        with self._database.sessions() as session, session.begin():
            return cast(
                "CursorResult[Any]",
                session.execute(
                    update(BuildJobRecord)
                    .where(
                        BuildJobRecord.status == JobStatus.RUNNING.value,
                        or_(
                            BuildJobRecord.heartbeat_at < threshold,
                            BuildJobRecord.heartbeat_at.is_(None),
                        ),
                    )
                    .values(
                        status=JobStatus.QUEUED.value,
                        stage=ProductionStage.QUEUED.value,
                        error_code="lease_expired",
                        error_message="Recovered a job whose worker lease expired",
                    )
                ),
            ).rowcount

    def claim_next(self) -> BuildJob | None:
        now = self._now()
        with self._database.engine.connect() as connection:
            # BEGIN IMMEDIATE acquires the write lock BEFORE the SELECT so two
            # workers cannot both lease the same QUEUED row.
            connection.execute(text("BEGIN IMMEDIATE"))
            job_id = connection.scalar(
                select(BuildJobRecord.job_id)
                .where(BuildJobRecord.status == JobStatus.QUEUED.value)
                .order_by(BuildJobRecord.created_at)
                .limit(1)
            )
            if job_id is None:
                connection.rollback()
                return None
            connection.execute(
                update(BuildJobRecord)
                .where(BuildJobRecord.job_id == job_id)
                .values(
                    status=JobStatus.RUNNING.value,
                    stage=ProductionStage.TRANSLATION.value,
                    attempts=BuildJobRecord.attempts + 1,
                    started_at=func.coalesce(BuildJobRecord.started_at, now),
                    heartbeat_at=now,
                    finished_at=None,
                    error_code=None,
                    error_message=None,
                )
            )
            connection.commit()
        return self.get(job_id)

    def checkpoint(
        self,
        job_id: str,
        stage: ProductionStage,
        checkpoint_json: str | None = None,
    ) -> None:
        with self._database.sessions() as session, session.begin():
            updated = cast(
                "CursorResult[Any]",
                session.execute(
                    update(BuildJobRecord)
                    .where(
                        BuildJobRecord.job_id == job_id,
                        BuildJobRecord.status == JobStatus.RUNNING.value,
                    )
                    .values(
                        stage=stage.value,
                        checkpoint_json=func.coalesce(
                            checkpoint_json, BuildJobRecord.checkpoint_json
                        ),
                        heartbeat_at=self._now(),
                    )
                ),
            ).rowcount
            if updated != 1:
                raise InvalidJobState("only a running job can save a checkpoint")

    def require_review(self, job_id: str) -> None:
        now = self._now()
        with self._database.sessions() as session, session.begin():
            updated = cast(
                "CursorResult[Any]",
                session.execute(
                    update(BuildJobRecord)
                    .where(
                        BuildJobRecord.job_id == job_id,
                        BuildJobRecord.status == JobStatus.RUNNING.value,
                    )
                    .values(
                        status=JobStatus.REVIEW_REQUIRED.value,
                        stage=ProductionStage.REVIEW.value,
                        heartbeat_at=now,
                        finished_at=now,
                    )
                ),
            ).rowcount
            if updated != 1:
                raise InvalidJobState("only a running job can enter review")

    def set_review_stage(self, job_id: str, stage: ProductionStage) -> None:
        if stage not in {ProductionStage.PACKAGING, ProductionStage.PUBLISHING}:
            raise ValueError("review jobs can only enter packaging or publishing")
        with self._database.sessions() as session, session.begin():
            updated = cast(
                "CursorResult[Any]",
                session.execute(
                    update(BuildJobRecord)
                    .where(
                        BuildJobRecord.job_id == job_id,
                        BuildJobRecord.status == JobStatus.REVIEW_REQUIRED.value,
                    )
                    .values(stage=stage.value, heartbeat_at=self._now())
                ),
            ).rowcount
            if updated != 1:
                raise InvalidJobState("only a review job can advance release stages")

    def fail(self, job_id: str, code: str, message: str) -> None:
        now = self._now()
        with self._database.sessions() as session, session.begin():
            session.execute(
                update(BuildJobRecord)
                .where(
                    BuildJobRecord.job_id == job_id,
                    BuildJobRecord.status != JobStatus.SUCCEEDED.value,
                )
                .values(
                    status=JobStatus.FAILED.value,
                    finished_at=now,
                    heartbeat_at=now,
                    error_code=code,
                    error_message=message[:2000],
                )
            )

    def retry(self, job_id: str) -> BuildJob:
        with self._database.sessions() as session, session.begin():
            updated = cast(
                "CursorResult[Any]",
                session.execute(
                    update(BuildJobRecord)
                    .where(
                        BuildJobRecord.job_id == job_id,
                        BuildJobRecord.status.in_(
                            [JobStatus.FAILED.value, JobStatus.REVIEW_REQUIRED.value]
                        ),
                    )
                    .values(
                        status=JobStatus.QUEUED.value,
                        stage=ProductionStage.QUEUED.value,
                        finished_at=None,
                    )
                ),
            ).rowcount
            if updated != 1:
                raise InvalidJobState("only failed or review jobs can be retried")
        return self.get(job_id)

    def mark_succeeded(self, job_id: str) -> None:
        with self._database.sessions() as session, session.begin():
            updated = cast(
                "CursorResult[Any]",
                session.execute(
                    update(BuildJobRecord)
                    .where(
                        BuildJobRecord.job_id == job_id,
                        BuildJobRecord.status == JobStatus.REVIEW_REQUIRED.value,
                    )
                    .values(
                        status=JobStatus.SUCCEEDED.value,
                        stage=ProductionStage.COMPLETE.value,
                        finished_at=self._now(),
                    )
                ),
            ).rowcount
            if updated != 1:
                raise InvalidJobState("only a reviewed job can succeed")
