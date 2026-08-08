from __future__ import annotations

from pathlib import Path

import pytest

from engirdle_pc.modules.speech.application.voice_service import VoiceProfileService
from engirdle_pc.modules.speech.domain.models import (
    InvalidAnchorRequest,
    VoiceCandidateNotFound,
    VoiceIntegrityError,
    VoiceProfileNotConfigured,
)
from engirdle_pc.modules.speech.infrastructure.sqlalchemy_repository import (
    SqlAlchemyVoiceProfileRepository,
)
from engirdle_pc.shared.infrastructure.hashing import sha256_file
from engirdle_pc.shared.infrastructure.runtime import SystemClock, UuidIdentifierGenerator
from tests.speech_fake import FakeAnchorEngine

ANCHOR_TEXT = "A short English anchor read aloud for the candidates."


@pytest.fixture
def engine() -> FakeAnchorEngine:
    return FakeAnchorEngine()


@pytest.fixture
def service(database, engine, tmp_path: Path) -> VoiceProfileService:
    return VoiceProfileService(
        engine,
        SqlAlchemyVoiceProfileRepository(database),
        tmp_path / "voices",
        SystemClock(),
        UuidIdentifierGenerator(),
    )


def _create_batch(service: VoiceProfileService, count: int = 2):
    return service.create_anchor_batch(
        speaker="Ryan",
        anchor_text=ANCHOR_TEXT,
        instruct="Calm, steady narration.",
        seed=10,
        count=count,
    )


def test_create_batch_persists_rows_and_files(service, engine, tmp_path: Path) -> None:
    batch = _create_batch(service)

    assert len(batch.candidates) == 2
    assert batch.custom_voice_model == engine.custom_voice_model
    assert batch.model_fingerprint == engine.model_fingerprint
    for index, candidate in enumerate(batch.candidates):
        assert candidate.seed == 10 + index
        assert candidate.wav_path.is_file()
        assert candidate.wav_path.parent == tmp_path / "voices" / "_candidates" / batch.batch_id
        assert candidate.sha256 == sha256_file(candidate.wav_path)
        assert candidate.duration_ms == 500
    assert engine.calls[0]["speaker"] == "Ryan"

    loaded = service.get_batch(batch.batch_id)
    assert loaded.anchor_text == ANCHOR_TEXT
    assert [c.candidate_index for c in loaded.candidates] == [0, 1]
    assert [b.batch_id for b in service.list_batches()] == [batch.batch_id]


def test_confirm_freezes_revision_and_activates(service, tmp_path: Path) -> None:
    batch = _create_batch(service)
    profile = service.confirm_candidate(batch.batch_id, 1)

    assert profile.revision == 1
    assert profile.is_active is True
    assert profile.speaker == "Ryan"
    assert profile.anchor_text == ANCHOR_TEXT
    assert profile.seed == 11
    anchor_path = tmp_path / "voices" / profile.voice_profile_id / "1" / "anchor.wav"
    assert profile.anchor_wav_path == anchor_path
    assert anchor_path.is_file()
    assert profile.anchor_sha256 == sha256_file(anchor_path) == batch.candidates[1].sha256
    assert service.active_profile().voice_profile_id == profile.voice_profile_id


def test_second_confirm_creates_a_new_immutable_revision(
    service, tmp_path: Path
) -> None:
    batch = _create_batch(service)
    first = service.confirm_candidate(batch.batch_id, 0)
    first_bytes = first.anchor_wav_path.read_bytes()

    second = service.confirm_candidate(
        batch.batch_id, 1, voice_profile_id=first.voice_profile_id
    )

    assert second.revision == 2
    assert second.voice_profile_id == first.voice_profile_id
    assert second.anchor_wav_path != first.anchor_wav_path
    assert first.anchor_wav_path.read_bytes() == first_bytes  # revision 1 untouched
    active = service.active_profile()
    assert (active.voice_profile_id, active.revision) == (first.voice_profile_id, 2)
    revisions = [p.revision for p in service.list_profiles()]
    assert revisions == [2, 1]


def test_activate_switches_the_single_active_pointer(service) -> None:
    batch = _create_batch(service)
    first = service.confirm_candidate(batch.batch_id, 0)
    service.confirm_candidate(
        batch.batch_id, 1, voice_profile_id=first.voice_profile_id
    )

    activated = service.activate(first.voice_profile_id, 1)
    assert activated.revision == 1
    profiles = {p.revision: p for p in service.list_profiles()}
    assert profiles[1].is_active is True
    assert profiles[2].is_active is False
    assert service.active_profile().revision == 1


def test_create_batch_rejects_invalid_input(service) -> None:
    with pytest.raises(InvalidAnchorRequest, match="speaker"):
        service.create_anchor_batch(
            speaker="Vivian", anchor_text=ANCHOR_TEXT, instruct="", seed=0, count=1
        )
    with pytest.raises(InvalidAnchorRequest, match="anchor text"):
        service.create_anchor_batch(
            speaker="Ryan", anchor_text="   ", instruct="", seed=0, count=1
        )
    with pytest.raises(InvalidAnchorRequest, match="seed"):
        service.create_anchor_batch(
            speaker="Ryan", anchor_text=ANCHOR_TEXT, instruct="", seed=-1, count=1
        )
    with pytest.raises(InvalidAnchorRequest, match="count"):
        service.create_anchor_batch(
            speaker="Ryan", anchor_text=ANCHOR_TEXT, instruct="", seed=0, count=0
        )


def test_confirm_unknown_batch_or_candidate(service) -> None:
    with pytest.raises(VoiceCandidateNotFound):
        service.confirm_candidate("missing-batch", 0)
    batch = _create_batch(service)
    with pytest.raises(VoiceCandidateNotFound):
        service.confirm_candidate(batch.batch_id, 99)


def test_confirm_rejects_unsafe_profile_id(service, tmp_path: Path) -> None:
    batch = _create_batch(service)
    for unsafe in ("../evil", "a/b", "..", "with space", "dots..inside"):
        with pytest.raises(InvalidAnchorRequest, match="voice_profile_id"):
            service.confirm_candidate(batch.batch_id, 0, voice_profile_id=unsafe)
    # Nothing escaped the controlled voices tree (design §5.1).
    assert not (tmp_path / "evil").exists()
    assert [p.name for p in (tmp_path / "voices").iterdir()] == ["_candidates"]


def test_confirm_missing_candidate_wav_cleans_up_orphans(
    service, tmp_path: Path
) -> None:
    batch = _create_batch(service)
    batch.candidates[0].wav_path.unlink()

    with pytest.raises(VoiceCandidateNotFound, match="candidate WAV is missing"):
        service.confirm_candidate(batch.batch_id, 0)

    # The half-created anchor dir was removed; the candidate dir stays.
    assert [p.name for p in (tmp_path / "voices").iterdir()] == ["_candidates"]


def test_confirm_hash_mismatch_is_integrity_error_and_cleans_up(
    service, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    batch = _create_batch(service)
    monkeypatch.setattr(
        "engirdle_pc.modules.speech.application.voice_service.sha256_file",
        lambda _path: "0" * 64,
    )

    with pytest.raises(VoiceIntegrityError, match="hash differs"):
        service.confirm_candidate(batch.batch_id, 0)

    assert [p.name for p in (tmp_path / "voices").iterdir()] == ["_candidates"]
    assert service.list_profiles() == ()


def test_engine_candidate_count_mismatch_is_integrity_error(
    service, engine: FakeAnchorEngine, monkeypatch: pytest.MonkeyPatch
) -> None:
    original = engine.generate_candidates

    def returns_fewer(**kwargs: object) -> object:
        # Service asked for 2; a misbehaving engine returns only 1.
        return original(**{**kwargs, "count": 1})

    monkeypatch.setattr(engine, "generate_candidates", returns_fewer)
    with pytest.raises(VoiceIntegrityError, match="candidates"):
        _create_batch(service, count=2)


def test_active_profile_requires_confirmation(service) -> None:
    with pytest.raises(VoiceProfileNotConfigured):
        service.active_profile()
    with pytest.raises(VoiceCandidateNotFound):
        service.activate("missing-profile", 1)
