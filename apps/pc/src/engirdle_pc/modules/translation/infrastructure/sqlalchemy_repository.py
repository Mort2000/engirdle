from __future__ import annotations

from typing import Any, cast

from sqlalchemy import select, text, update
from sqlalchemy.dialects.sqlite import insert
from sqlalchemy.engine import CursorResult

from engirdle_pc.modules.translation.application.ports import (
    ReviewedTranslation,
    SentenceTranslation,
)
from engirdle_pc.modules.translation.infrastructure.orm import TranslationRecord
from engirdle_pc.shared.infrastructure.database.connection import Database


class SqlAlchemyTranslationRepository:
    """SQLAlchemy 2.0 implementation of the ``TranslationStore`` protocol."""

    def __init__(self, database: Database) -> None:
        self._database = database

    def save(
        self,
        job_id: str,
        translations: tuple[SentenceTranslation, ...],
        adapter_name: str,
    ) -> None:
        # executemany with an empty batch is a no-op in raw sqlite3; guard it
        # because session.execute(insert(...), []) compiles to a single
        # "INSERT ... DEFAULT VALUES" that SQLite rejects here.
        if not translations:
            return
        stmt = insert(TranslationRecord)
        stmt = stmt.on_conflict_do_update(
            index_elements=["job_id", "sentence_id"],
            set_={
                "generated_text": stmt.excluded.generated_text,
                "adapter_name": stmt.excluded.adapter_name,
            },
        )
        with self._database.sessions() as session, session.begin():
            session.execute(
                stmt,
                [
                    {
                        "job_id": job_id,
                        "sentence_id": translation.sentence_id,
                        "generated_text": translation.text_zh,
                        "adapter_name": adapter_name,
                    }
                    for translation in translations
                ],
            )

    def edit(self, job_id: str, sentence_id: str, text: str) -> None:
        with self._database.sessions() as session, session.begin():
            result = cast(
                "CursorResult[Any]",
                session.execute(
                    update(TranslationRecord)
                    .where(
                        TranslationRecord.job_id == job_id,
                        TranslationRecord.sentence_id == sentence_id,
                    )
                    .values(edited_text=text.strip()),
                ),
            )
            if result.rowcount != 1:
                raise KeyError(f"translation {job_id}/{sentence_id} not found")

    def list_for_job(self, job_id: str) -> tuple[ReviewedTranslation, ...]:
        with self._database.sessions() as session, session.begin():
            records = session.scalars(
                select(TranslationRecord)
                .where(TranslationRecord.job_id == job_id)
                .order_by(text("rowid"))
            )
            return tuple(
                ReviewedTranslation(
                    sentence_id=record.sentence_id,
                    generated_text=record.generated_text,
                    edited_text=record.edited_text,
                )
                for record in records
            )
