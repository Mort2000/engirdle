from __future__ import annotations

from engirdle_pc.modules.translation.application.ports import (
    ReviewedTranslation,
    SentenceTranslation,
)
from engirdle_pc.shared.infrastructure.database.connection import Database


class TranslationRepository:
    def __init__(self, database: Database) -> None:
        self._database = database

    def save(
        self, job_id: str, translations: tuple[SentenceTranslation, ...], adapter_name: str
    ) -> None:
        with self._database.connect() as connection:
            connection.executemany(
                """
                INSERT INTO translations(job_id, sentence_id, generated_text, adapter_name)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(job_id, sentence_id) DO UPDATE SET
                    generated_text = excluded.generated_text,
                    adapter_name = excluded.adapter_name
                """,
                [
                    (job_id, translation.sentence_id, translation.text_zh, adapter_name)
                    for translation in translations
                ],
            )

    def edit(self, job_id: str, sentence_id: str, text: str) -> None:
        with self._database.connect() as connection:
            updated = connection.execute(
                """
                UPDATE translations SET edited_text = ?
                WHERE job_id = ? AND sentence_id = ?
                """,
                (text.strip(), job_id, sentence_id),
            ).rowcount
            if updated != 1:
                raise KeyError(f"translation {job_id}/{sentence_id} not found")

    def list_for_job(self, job_id: str) -> tuple[ReviewedTranslation, ...]:
        with self._database.connect() as connection:
            rows = connection.execute(
                """
                SELECT sentence_id, generated_text, edited_text FROM translations
                WHERE job_id = ? ORDER BY rowid
                """,
                (job_id,),
            ).fetchall()
            return tuple(
                ReviewedTranslation(
                    sentence_id=row["sentence_id"],
                    generated_text=row["generated_text"],
                    edited_text=row["edited_text"],
                )
                for row in rows
            )
