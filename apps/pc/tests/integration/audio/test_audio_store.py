from __future__ import annotations

from pathlib import Path

from engirdle_pc.modules.audio.application.models import AudioOutput
from engirdle_pc.modules.audio.domain.models import SentenceTiming
from engirdle_pc.modules.audio.infrastructure.sqlalchemy_repository import (
    SqlAlchemyAudioRepository,
)


def test_audio_save_with_empty_timings_still_upserts_output(
    database, seed_build_job, tmp_path: Path
) -> None:
    seed_build_job()
    store = SqlAlchemyAudioRepository(database)

    store.save(
        "job-1",
        AudioOutput(
            path=tmp_path / "out.m4a",
            sample_rate_hz=24000,
            channels=1,
            duration_ms=100,
            encoder_version="v1",
            timings=(),  # empty — must not raise (regression guard)
        ),
    )

    fetched = store.get("job-1")
    assert fetched.timings == ()
    assert fetched.encoder_version == "v1"


def test_audio_save_and_get_round_trip(database, seed_build_job, tmp_path: Path) -> None:
    seed_build_job()
    store = SqlAlchemyAudioRepository(database)

    store.save(
        "job-1",
        AudioOutput(
            path=tmp_path / "out.m4a",
            sample_rate_hz=24000,
            channels=1,
            duration_ms=500,
            encoder_version="v1",
            timings=(
                SentenceTiming("s1", 0, 100, 0, 200),
                SentenceTiming("s2", 100, 240, 200, 500),
            ),
        ),
    )

    fetched = store.get("job-1")
    assert [t.sentence_id for t in fetched.timings] == ["s1", "s2"]
    assert fetched.sample_rate_hz == 24000
