from __future__ import annotations

from sqlalchemy import ForeignKeyConstraint
from sqlalchemy.orm import Mapped, mapped_column

from engirdle_pc.modules.production.domain.models import (
    BuildJob,
    JobStatus,
    PipelineConfig,
    ProductionStage,
)
from engirdle_pc.shared.infrastructure.database.base import Base


class BuildJobRecord(Base):
    """ORM mapping for the ``build_jobs`` table.

    Read/write mapping only; DDL (single PK, composite FK to
    ``article_revisions``) is owned by the Alembic baseline. Enum columns store
    ``.value`` strings; ``config_json`` is serialized via ``PipelineConfig``.
    """

    __tablename__ = "build_jobs"
    __table_args__ = (
        ForeignKeyConstraint(
            ["article_id", "revision"],
            ["article_revisions.article_id", "article_revisions.revision"],
        ),
    )

    job_id: Mapped[str] = mapped_column(primary_key=True)
    article_id: Mapped[str]
    revision: Mapped[int]
    status: Mapped[str]
    stage: Mapped[str]
    attempts: Mapped[int]
    config_json: Mapped[str]
    checkpoint_json: Mapped[str | None]
    created_at: Mapped[str]
    started_at: Mapped[str | None]
    heartbeat_at: Mapped[str | None]
    finished_at: Mapped[str | None]
    error_code: Mapped[str | None]
    error_message: Mapped[str | None]

    def to_dataclass(self) -> BuildJob:
        return BuildJob(
            job_id=self.job_id,
            article_id=self.article_id,
            revision=self.revision,
            status=JobStatus(self.status),
            stage=ProductionStage(self.stage),
            attempts=self.attempts,
            config=PipelineConfig.from_json(self.config_json),
            checkpoint_json=self.checkpoint_json,
            created_at=self.created_at,
            started_at=self.started_at,
            heartbeat_at=self.heartbeat_at,
            finished_at=self.finished_at,
            error_code=self.error_code,
            error_message=self.error_message,
        )
