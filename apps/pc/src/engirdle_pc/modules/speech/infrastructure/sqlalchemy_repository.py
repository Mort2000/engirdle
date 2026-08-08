from __future__ import annotations

from pathlib import Path

from sqlalchemy import select, text
from sqlalchemy.dialects.sqlite import insert

from engirdle_pc.modules.speech.application.ports import SentenceSpeech
from engirdle_pc.modules.speech.infrastructure.orm import SentenceAudioRecord
from engirdle_pc.shared.infrastructure.database.connection import Database


class SqlAlchemySpeechRepository:
    """SQLAlchemy 2.0 implementation of the ``SpeechStore`` protocol."""

    def __init__(self, database: Database) -> None:
        self._database = database

    def save(self, job_id: str, speech: SentenceSpeech, adapter_name: str) -> None:
        stmt = insert(SentenceAudioRecord).values(
            job_id=job_id,
            sentence_id=speech.sentence_id,
            pcm_path=str(speech.pcm_path),
            sample_rate_hz=speech.sample_rate_hz,
            sample_count=speech.sample_count,
            adapter_name=adapter_name,
        )
        stmt = stmt.on_conflict_do_update(
            index_elements=["job_id", "sentence_id"],
            set_={
                "pcm_path": stmt.excluded.pcm_path,
                "sample_rate_hz": stmt.excluded.sample_rate_hz,
                "sample_count": stmt.excluded.sample_count,
                "adapter_name": stmt.excluded.adapter_name,
            },
        )
        with self._database.sessions() as session, session.begin():
            session.execute(stmt)

    def list_reusable_for_job(
        self, job_id: str, adapter_name: str
    ) -> tuple[SentenceSpeech, ...]:
        with self._database.sessions() as session, session.begin():
            records = session.scalars(
                select(SentenceAudioRecord)
                .where(
                    SentenceAudioRecord.job_id == job_id,
                    SentenceAudioRecord.adapter_name == adapter_name,
                )
                .order_by(text("rowid"))
            )
            candidates = tuple(
                SentenceSpeech(
                    sentence_id=record.sentence_id,
                    pcm_path=Path(record.pcm_path),
                    sample_rate_hz=record.sample_rate_hz,
                    sample_count=record.sample_count,
                )
                for record in records
            )
        return tuple(speech for speech in candidates if _is_valid_pcm(speech))


def _is_valid_pcm(speech: SentenceSpeech) -> bool:
    return (
        speech.sample_rate_hz > 0
        and speech.sample_count > 0
        and speech.pcm_path.is_file()
        and speech.pcm_path.stat().st_size == speech.sample_count * 2
    )
