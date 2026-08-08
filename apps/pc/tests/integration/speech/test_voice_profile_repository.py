from __future__ import annotations

from pathlib import Path

import pytest

from engirdle_pc.modules.speech.domain.models import (
    AnchorBatch,
    AnchorCandidate,
    VoiceProfile,
)
from engirdle_pc.modules.speech.infrastructure.sqlalchemy_repository import (
    SqlAlchemyVoiceProfileRepository,
)

NOW = "2026-01-01T00:00:00Z"


def _batch(batch_id: str = "batch-1") -> AnchorBatch:
    return AnchorBatch(
        batch_id=batch_id,
        speaker="Ryan",
        instruct="Calm.",
        anchor_text="Anchor text.",
        seed=3,
        custom_voice_model="Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice@fake",
        model_fingerprint="fake-fingerprint",
        created_at=NOW,
        candidates=tuple(
            AnchorCandidate(
                batch_id=batch_id,
                candidate_index=index,
                seed=3 + index,
                wav_path=Path(f"/tmp/{batch_id}/candidate_{index}.wav"),
                sha256=f"sha-{batch_id}-{index}",
                duration_ms=500,
                sample_rate_hz=24_000,
            )
            for index in range(2)
        ),
    )


def _profile(profile_id: str, revision: int, *, active: bool) -> VoiceProfile:
    return VoiceProfile(
        voice_profile_id=profile_id,
        revision=revision,
        speaker="Ryan",
        instruct="",
        anchor_text="Anchor text.",
        anchor_wav_path=Path(f"/tmp/{profile_id}/{revision}/anchor.wav"),
        anchor_sha256=f"anchor-sha-{revision}",
        sample_rate_hz=24_000,
        duration_ms=500,
        seed=3,
        generation_params_json='{"seed": 3}',
        custom_voice_model="Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice@fake",
        model_fingerprint="fake-fingerprint",
        source_batch_id="batch-1",
        is_active=active,
        created_at=NOW,
        confirmed_at=NOW,
    )


@pytest.fixture
def repository(database) -> SqlAlchemyVoiceProfileRepository:
    return SqlAlchemyVoiceProfileRepository(database)


def test_batch_round_trip(repository) -> None:
    repository.save_batch(_batch())
    loaded = repository.get_batch("batch-1")
    assert loaded.speaker == "Ryan"
    assert loaded.instruct == "Calm."
    assert [c.sha256 for c in loaded.candidates] == ["sha-batch-1-0", "sha-batch-1-1"]
    assert [b.batch_id for b in repository.list_batches()] == ["batch-1"]
    with pytest.raises(KeyError):
        repository.get_batch("missing")


def test_confirmed_profile_round_trip_and_single_active(repository) -> None:
    repository.save_confirmed_profile(_profile("voice-a", 1, active=True))
    active = repository.active_profile()
    assert active is not None
    assert (active.voice_profile_id, active.revision) == ("voice-a", 1)
    assert active.is_active is True

    # Confirming another revision moves the active pointer atomically.
    repository.save_confirmed_profile(_profile("voice-a", 2, active=True))
    active = repository.active_profile()
    assert active is not None and active.revision == 2
    assert repository.latest_revision("voice-a") == 2
    assert repository.latest_revision("voice-b") == 0
    by_revision = {
        p.revision: p for p in repository.list_profiles() if p.voice_profile_id == "voice-a"
    }
    assert by_revision[1].is_active is False
    assert by_revision[2].is_active is True

    repository.activate("voice-a", 1)
    assert repository.active_profile().revision == 1
    assert repository.get_profile("voice-a", 2).is_active is False
    with pytest.raises(KeyError):
        repository.activate("voice-a", 99)
    with pytest.raises(KeyError):
        repository.get_profile("voice-a", 99)


def test_active_profile_is_none_before_any_confirmation(repository) -> None:
    assert repository.active_profile() is None
    assert repository.list_profiles() == ()
