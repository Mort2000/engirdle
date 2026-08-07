from __future__ import annotations

from pathlib import Path

from engirdle_pc.modules.speech.application.ports import SentenceSpeech
from engirdle_pc.shared.infrastructure.database.connection import Database


class SpeechRepository:
    def __init__(self, database: Database) -> None:
        self._database = database

    def save(self, job_id: str, speech: SentenceSpeech, adapter_name: str) -> None:
        with self._database.connect() as connection:
            connection.execute(
                """
                INSERT INTO sentence_audio(
                    job_id, sentence_id, pcm_path, sample_rate_hz, sample_count, adapter_name
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(job_id, sentence_id) DO UPDATE SET
                    pcm_path = excluded.pcm_path,
                    sample_rate_hz = excluded.sample_rate_hz,
                    sample_count = excluded.sample_count,
                    adapter_name = excluded.adapter_name
                """,
                (
                    job_id,
                    speech.sentence_id,
                    str(speech.pcm_path),
                    speech.sample_rate_hz,
                    speech.sample_count,
                    adapter_name,
                ),
            )

    def list_for_job(self, job_id: str) -> tuple[SentenceSpeech, ...]:
        with self._database.connect() as connection:
            rows = connection.execute(
                """
                SELECT sentence_id, pcm_path, sample_rate_hz, sample_count
                FROM sentence_audio WHERE job_id = ? ORDER BY rowid
                """,
                (job_id,),
            ).fetchall()
            return tuple(
                SentenceSpeech(
                    sentence_id=row["sentence_id"],
                    pcm_path=Path(row["pcm_path"]),
                    sample_rate_hz=row["sample_rate_hz"],
                    sample_count=row["sample_count"],
                )
                for row in rows
            )
