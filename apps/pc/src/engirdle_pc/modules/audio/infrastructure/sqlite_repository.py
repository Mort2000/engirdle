from __future__ import annotations

from pathlib import Path

from engirdle_pc.modules.audio.application.models import AudioOutput
from engirdle_pc.modules.audio.domain.models import SentenceTiming
from engirdle_pc.shared.infrastructure.database.connection import Database


class AudioRepository:
    def __init__(self, database: Database) -> None:
        self._database = database

    def save(self, job_id: str, output: AudioOutput) -> None:
        with self._database.connect() as connection:
            connection.execute("DELETE FROM audio_timeline WHERE job_id = ?", (job_id,))
            connection.executemany(
                """
                INSERT INTO audio_timeline(
                    job_id, sentence_id, start_sample, end_sample, start_ms, end_ms
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        job_id,
                        timing.sentence_id,
                        timing.start_sample,
                        timing.end_sample,
                        timing.start_ms,
                        timing.end_ms,
                    )
                    for timing in output.timings
                ],
            )
            connection.execute(
                """
                INSERT INTO audio_outputs(
                    job_id, path, sample_rate_hz, channels, duration_ms, encoder_version
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(job_id) DO UPDATE SET
                    path = excluded.path,
                    sample_rate_hz = excluded.sample_rate_hz,
                    channels = excluded.channels,
                    duration_ms = excluded.duration_ms,
                    encoder_version = excluded.encoder_version
                """,
                (
                    job_id,
                    str(output.path),
                    output.sample_rate_hz,
                    output.channels,
                    output.duration_ms,
                    output.encoder_version,
                ),
            )

    def get(self, job_id: str) -> AudioOutput:
        with self._database.connect() as connection:
            row = connection.execute(
                "SELECT * FROM audio_outputs WHERE job_id = ?", (job_id,)
            ).fetchone()
            if row is None:
                raise KeyError(f"audio output for job {job_id} not found")
            timing_rows = connection.execute(
                "SELECT * FROM audio_timeline WHERE job_id = ? ORDER BY start_sample",
                (job_id,),
            ).fetchall()
            return AudioOutput(
                path=Path(row["path"]),
                sample_rate_hz=row["sample_rate_hz"],
                channels=row["channels"],
                duration_ms=row["duration_ms"],
                encoder_version=row["encoder_version"],
                timings=tuple(
                    SentenceTiming(
                        sentence_id=timing["sentence_id"],
                        start_sample=timing["start_sample"],
                        end_sample=timing["end_sample"],
                        start_ms=timing["start_ms"],
                        end_ms=timing["end_ms"],
                    )
                    for timing in timing_rows
                ),
            )
