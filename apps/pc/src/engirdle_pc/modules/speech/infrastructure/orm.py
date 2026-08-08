from __future__ import annotations

from sqlalchemy import ForeignKey
from sqlalchemy.orm import Mapped, mapped_column

from engirdle_pc.shared.infrastructure.database.base import Base


class SentenceAudioRecord(Base):
    """ORM mapping for the ``sentence_audio`` table.

    Read/write mapping only; remaining DDL (composite PK) is owned by the
    Alembic baseline.
    """

    __tablename__ = "sentence_audio"

    job_id: Mapped[str] = mapped_column(
        ForeignKey("build_jobs.job_id", ondelete="CASCADE"), primary_key=True
    )
    sentence_id: Mapped[str] = mapped_column(primary_key=True)
    pcm_path: Mapped[str]
    sample_rate_hz: Mapped[int]
    sample_count: Mapped[int]
    adapter_name: Mapped[str]
