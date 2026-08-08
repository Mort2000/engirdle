from __future__ import annotations

from sqlalchemy import ForeignKey
from sqlalchemy.orm import Mapped, mapped_column

from engirdle_pc.shared.infrastructure.database.base import Base


class AudioTimelineRecord(Base):
    """ORM mapping for the ``audio_timeline`` table.

    Read/write mapping only; remaining DDL (composite PK) is owned by the
    Alembic baseline.
    """

    __tablename__ = "audio_timeline"

    job_id: Mapped[str] = mapped_column(
        ForeignKey("build_jobs.job_id", ondelete="CASCADE"), primary_key=True
    )
    sentence_id: Mapped[str] = mapped_column(primary_key=True)
    start_sample: Mapped[int]
    end_sample: Mapped[int]
    start_ms: Mapped[int]
    end_ms: Mapped[int]


class AudioOutputRecord(Base):
    """ORM mapping for the ``audio_outputs`` table (read/write mapping only;
    DDL/PK owned by the Alembic baseline)."""

    __tablename__ = "audio_outputs"

    job_id: Mapped[str] = mapped_column(
        ForeignKey("build_jobs.job_id", ondelete="CASCADE"), primary_key=True
    )
    path: Mapped[str]
    sample_rate_hz: Mapped[int]
    channels: Mapped[int]
    duration_ms: Mapped[int]
    encoder_version: Mapped[str]
