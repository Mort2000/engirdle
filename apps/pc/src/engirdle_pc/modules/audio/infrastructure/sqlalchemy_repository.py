from __future__ import annotations

from pathlib import Path

from sqlalchemy import delete, select
from sqlalchemy.dialects.sqlite import insert

from engirdle_pc.modules.audio.application.models import AudioOutput
from engirdle_pc.modules.audio.domain.models import SentenceTiming
from engirdle_pc.modules.audio.infrastructure.orm import (
    AudioOutputRecord,
    AudioTimelineRecord,
)
from engirdle_pc.shared.infrastructure.database.connection import Database


class SqlAlchemyAudioRepository:
    """SQLAlchemy 2.0 implementation of the ``AudioStore`` protocol."""

    def __init__(self, database: Database) -> None:
        self._database = database

    def save(self, job_id: str, output: AudioOutput) -> None:
        upsert = insert(AudioOutputRecord).values(
            job_id=job_id,
            path=str(output.path),
            sample_rate_hz=output.sample_rate_hz,
            channels=output.channels,
            duration_ms=output.duration_ms,
            encoder_version=output.encoder_version,
        )
        upsert = upsert.on_conflict_do_update(
            index_elements=["job_id"],
            set_={
                "path": upsert.excluded.path,
                "sample_rate_hz": upsert.excluded.sample_rate_hz,
                "channels": upsert.excluded.channels,
                "duration_ms": upsert.excluded.duration_ms,
                "encoder_version": upsert.excluded.encoder_version,
            },
        )
        with self._database.sessions() as session, session.begin():
            session.execute(
                delete(AudioTimelineRecord).where(AudioTimelineRecord.job_id == job_id)
            )
            # executemany with an empty batch is a no-op in raw sqlite3; guard it
            # because session.execute(insert(...), []) compiles to a single
            # "INSERT ... DEFAULT VALUES" that violates NOT NULL columns.
            if output.timings:
                session.execute(
                    insert(AudioTimelineRecord),
                    [
                        {
                            "job_id": job_id,
                            "sentence_id": timing.sentence_id,
                            "start_sample": timing.start_sample,
                            "end_sample": timing.end_sample,
                            "start_ms": timing.start_ms,
                            "end_ms": timing.end_ms,
                        }
                        for timing in output.timings
                    ],
                )
            session.execute(upsert)

    def get(self, job_id: str) -> AudioOutput:
        with self._database.sessions() as session, session.begin():
            output = session.get(AudioOutputRecord, job_id)
            if output is None:
                raise KeyError(f"audio output for job {job_id} not found")
            timings = session.scalars(
                select(AudioTimelineRecord)
                .where(AudioTimelineRecord.job_id == job_id)
                .order_by(AudioTimelineRecord.start_sample)
            )
            return AudioOutput(
                path=Path(output.path),
                sample_rate_hz=output.sample_rate_hz,
                channels=output.channels,
                duration_ms=output.duration_ms,
                encoder_version=output.encoder_version,
                timings=tuple(
                    SentenceTiming(
                        sentence_id=timing.sentence_id,
                        start_sample=timing.start_sample,
                        end_sample=timing.end_sample,
                        start_ms=timing.start_ms,
                        end_ms=timing.end_ms,
                    )
                    for timing in timings
                ),
            )
