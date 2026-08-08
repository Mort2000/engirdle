from __future__ import annotations

from sqlalchemy import ForeignKey
from sqlalchemy.orm import Mapped, mapped_column

from engirdle_pc.shared.infrastructure.database.base import Base


class TranslationRecord(Base):
    """ORM mapping for the ``translations`` table.

    Read/write mapping only; remaining DDL (composite PK) is owned by the
    Alembic baseline.
    """

    __tablename__ = "translations"

    job_id: Mapped[str] = mapped_column(
        ForeignKey("build_jobs.job_id", ondelete="CASCADE"), primary_key=True
    )
    sentence_id: Mapped[str] = mapped_column(primary_key=True)
    generated_text: Mapped[str]
    edited_text: Mapped[str | None]
    adapter_name: Mapped[str]
