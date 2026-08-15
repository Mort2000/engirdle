from __future__ import annotations

from sqlalchemy import ForeignKey
from sqlalchemy.orm import Mapped, mapped_column

from engirdle_pc.shared.infrastructure.database.base import Base


class TranslationUnitRecord(Base):
    """ORM mapping for the 'translation_units' table (design §8.4/§12.1).

    Read/write mapping only; DDL (composite PK) is owned by Alembic migration
    0004. The payload columns are boundary JSON; the repository decodes them
    into typed results immediately after reading.
    """

    __tablename__ = "translation_units"

    job_id: Mapped[str] = mapped_column(
        ForeignKey("build_jobs.job_id", ondelete="CASCADE"), primary_key=True
    )
    unit_id: Mapped[str] = mapped_column(primary_key=True)
    unit_kind: Mapped[str]
    generated_payload: Mapped[str]
    edited_payload: Mapped[str | None]
    adapter_name: Mapped[str]
