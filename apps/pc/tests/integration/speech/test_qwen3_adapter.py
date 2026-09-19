from __future__ import annotations

import json
import math
import wave
from array import array
from pathlib import Path

import pytest

from engirdle_pc.modules.speech.application.ports import SpeechRequest
from engirdle_pc.modules.speech.application.service import InvalidSpeechResult
from engirdle_pc.modules.speech.domain.models import (
    VoiceProfile,
    VoiceProfileNotConfigured,
)
from engirdle_pc.modules.speech.infrastructure.qwen3_adapter import Qwen3SpeechAdapter
from engirdle_pc.modules.speech.infrastructure.qwen3_backend import (
    GeneratedWaveform,
    SpeechConfigurationError,
    checkpoint_fingerprint,
)
from engirdle_pc.modules.speech.infrastructure.sqlalchemy_repository import (
    SqlAlchemyVoiceProfileRepository,
)
from engirdle_pc.shared.infrastructure.hashing import sha256_file
from tests.speech_fake import FakeQwen3Backend


def _write_wav(path: Path, frequency: float = 220.0) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    sample_rate = 24_000
    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(
            array(
                "h",
                (
                    round(8_000 * math.sin(2 * math.pi * frequency * i / sample_rate))
                    for i in range(sample_rate // 2)
                ),
            ).tobytes()
        )
    return path


def _profile(tmp_path: Path, profile_id: str, revision: int, sha: str | None) -> VoiceProfile:
    anchor = tmp_path / "voices" / profile_id / str(revision) / "anchor.wav"
    return VoiceProfile(
        voice_profile_id=profile_id,
        revision=revision,
        speaker="Ryan",
        instruct="",
        anchor_text="An anchor sentence for cloning.",
        anchor_wav_path=anchor,
        anchor_sha256=sha or "0" * 64,
        sample_rate_hz=24_000,
        duration_ms=500,
        seed=0,
        generation_params_json=json.dumps({"seed": 0, "max_new_tokens": 2048}),
        custom_voice_model="Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice@fake",
        model_fingerprint="fake-fingerprint",
        source_batch_id="batch-1",
        is_active=True,
        created_at="2026-01-01T00:00:00Z",
        confirmed_at="2026-01-01T00:00:00Z",
    )


@pytest.fixture
def profiles(database):
    return SqlAlchemyVoiceProfileRepository(database)


@pytest.fixture
def active_profile(tmp_path: Path, profiles) -> VoiceProfile:
    anchor = _write_wav(tmp_path / "voices" / "voice-1" / "1" / "anchor.wav")
    profile = _profile(tmp_path, "voice-1", 1, sha256_file(anchor))
    profiles.save_confirmed_profile(profile)
    return profile


def _adapter(profiles, backend: FakeQwen3Backend, tmp_path: Path, seed: int = 7, batch_size=4):
    return Qwen3SpeechAdapter(
        profiles,
        backend,
        custom_voice_model_dir=tmp_path / "models" / "Qwen3-TTS-12Hz-1.7B-CustomVoice",
        base_model_dir=tmp_path / "models" / "Qwen3-TTS-12Hz-1.7B-Base",
        seed=seed,
        max_new_tokens=2_048,
        batch_size=batch_size,
    )


def test_synthesize_writes_pcm_and_reuses_one_prompt(
    tmp_path: Path, profiles, active_profile
) -> None:
    backend = FakeQwen3Backend()
    adapter = _adapter(profiles, backend, tmp_path)

    first = adapter.synthesize("s1", "First sentence.", tmp_path / "pcm")
    second = adapter.synthesize("s2", "Second sentence.", tmp_path / "pcm")

    assert first.sample_rate_hz == 24_000
    assert first.sample_count == 4_800
    assert first.pcm_path.stat().st_size == first.sample_count * 2
    assert second.pcm_path.is_file()
    # One clone prompt built from the confirmed anchor, reused across sentences.
    assert len(backend.clone_prompt_calls) == 1
    prompt_call = backend.clone_prompt_calls[0]
    assert prompt_call["ref_audio_path"] == active_profile.anchor_wav_path
    assert prompt_call["ref_text"] == active_profile.anchor_text
    assert len(backend.voice_clone_calls) == 2
    for call in backend.voice_clone_calls:
        assert call["language"] == "English"
        assert call["voice_clone_prompt"] is not None
        assert call["max_new_tokens"] == 2_048
    # The configured seed is applied before every sentence generation.
    assert backend.seeds == [7, 7]
    ref = adapter.voice_profile
    assert ref.voice_profile_id == "voice-1"
    assert ref.revision == 1
    assert ref.anchor_sha256 == active_profile.anchor_sha256


def test_batch_synthesizes_distinct_sentence_files_in_one_model_call(
    tmp_path: Path, profiles, active_profile
) -> None:
    backend = FakeQwen3Backend()
    adapter = _adapter(profiles, backend, tmp_path)
    results = adapter.synthesize_batch(
        (SpeechRequest("short", "Short."), SpeechRequest("long", "A longer sentence.")),
        tmp_path / "pcm",
    )
    assert tuple(result.sentence_id for result in results) == ("short", "long")
    assert all(result.pcm_path.stat().st_size == 9_600 for result in results)
    assert len(backend.voice_clone_calls) == 1
    assert backend.voice_clone_calls[0]["text"] == ["Short.", "A longer sentence."]
    assert backend.seeds == [7]
    assert len(backend.clone_prompt_calls) == 1


@pytest.mark.parametrize("invalid", ["missing", "extra", "invalid_last_wave"])
def test_bad_waveform_batch_writes_no_partial_pcm(tmp_path, profiles, active_profile, invalid):
    class BadWaveforms(FakeQwen3Backend):
        def generate_voice_clone_batch(self, **kwargs):
            waves = super().generate_voice_clone_batch(**kwargs)
            if invalid == "missing":
                return waves[:-1]
            if invalid == "extra":
                return (*waves, waves[0])
            return (waves[0], GeneratedWaveform([float("nan")], 24_000))

    adapter = _adapter(profiles, BadWaveforms(), tmp_path)
    with pytest.raises(InvalidSpeechResult):
        adapter.synthesize_batch(
            (SpeechRequest("a", "One."), SpeechRequest("b", "Two.")), tmp_path / "pcm"
        )
    assert not list((tmp_path / "pcm").glob("*.pcm"))


def test_prompt_is_rebuilt_for_a_new_profile_revision(
    tmp_path: Path, profiles, active_profile
) -> None:
    backend = FakeQwen3Backend()
    adapter = _adapter(profiles, backend, tmp_path)
    adapter.synthesize("s1", "First.", tmp_path / "pcm")

    anchor_v2 = _write_wav(
        tmp_path / "voices" / "voice-1" / "2" / "anchor.wav", frequency=330.0
    )
    profiles.save_confirmed_profile(_profile(tmp_path, "voice-1", 2, sha256_file(anchor_v2)))
    adapter.synthesize("s2", "Second.", tmp_path / "pcm")

    assert len(backend.clone_prompt_calls) == 2
    assert adapter.voice_profile.revision == 2


def test_synthesize_rejects_wrong_sample_rate(
    tmp_path: Path, profiles, active_profile
) -> None:
    backend = FakeQwen3Backend(sample_rate_hz=16_000)
    adapter = _adapter(profiles, backend, tmp_path)
    with pytest.raises(InvalidSpeechResult, match="16000 Hz"):
        adapter.synthesize("s1", "Text.", tmp_path / "pcm")


def test_synthesize_rejects_empty_audio(tmp_path: Path, profiles, active_profile) -> None:
    backend = FakeQwen3Backend()
    backend.waveform = []
    adapter = _adapter(profiles, backend, tmp_path)
    with pytest.raises(InvalidSpeechResult, match="empty audio"):
        adapter.synthesize("s1", "Text.", tmp_path / "pcm")


def test_synthesize_rejects_silent_audio(tmp_path: Path, profiles, active_profile) -> None:
    backend = FakeQwen3Backend()
    backend.waveform = [0.0] * 4_800
    adapter = _adapter(profiles, backend, tmp_path)
    with pytest.raises(InvalidSpeechResult, match="silent audio"):
        adapter.synthesize("s1", "Text.", tmp_path / "pcm")


def test_synthesize_rejects_non_finite_audio(
    tmp_path: Path, profiles, active_profile
) -> None:
    backend = FakeQwen3Backend()
    backend.waveform = [0.1, float("nan"), 0.2]
    adapter = _adapter(profiles, backend, tmp_path)
    with pytest.raises(InvalidSpeechResult, match="non-finite"):
        adapter.synthesize("s1", "Text.", tmp_path / "pcm")


def test_synthesize_requires_an_active_profile(tmp_path: Path, profiles) -> None:
    adapter = _adapter(profiles, FakeQwen3Backend(), tmp_path)
    with pytest.raises(VoiceProfileNotConfigured):
        _ = adapter.voice_profile
    with pytest.raises(VoiceProfileNotConfigured):
        adapter.synthesize("s1", "Text.", tmp_path / "pcm")


def test_synthesize_detects_anchor_tampering(
    tmp_path: Path, profiles, active_profile
) -> None:
    active_profile.anchor_wav_path.write_bytes(b"tampered")
    adapter = _adapter(profiles, FakeQwen3Backend(), tmp_path)
    with pytest.raises(SpeechConfigurationError, match="hash mismatch"):
        adapter.synthesize("s1", "Text.", tmp_path / "pcm")


def test_generation_config_id_tracks_parameters(tmp_path: Path, profiles) -> None:
    first = _adapter(profiles, FakeQwen3Backend(), tmp_path, seed=1)
    second = _adapter(profiles, FakeQwen3Backend(), tmp_path, seed=2)
    assert first.generation_config_id.startswith("qwen3-clone@v2:")
    assert first.generation_config_id != second.generation_config_id
    assert first.generation_config_id == _adapter(
        profiles, FakeQwen3Backend(), tmp_path, seed=1
    ).generation_config_id
    assert first.generation_config_id != _adapter(
        profiles, FakeQwen3Backend(), tmp_path, seed=1, batch_size=2
    ).generation_config_id


def test_verify_setup_requires_checkpoints(tmp_path: Path, profiles) -> None:
    adapter = _adapter(profiles, FakeQwen3Backend(), tmp_path)
    with pytest.raises(SpeechConfigurationError, match="missing required files"):
        adapter.verify_setup()

    for name in ("Qwen3-TTS-12Hz-1.7B-CustomVoice", "Qwen3-TTS-12Hz-1.7B-Base"):
        model_dir = tmp_path / "models" / name
        model_dir.mkdir(parents=True)
        (model_dir / "config.json").write_text("{}")
        (model_dir / "model.safetensors").write_bytes(b"weights")
    adapter.verify_setup()
    assert adapter.custom_voice_model.startswith(
        "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice@local:"
    )
    assert adapter.base_model.startswith("Qwen/Qwen3-TTS-12Hz-1.7B-Base@local:")


def test_checkpoint_fingerprint_is_stable_and_sensitive(tmp_path: Path) -> None:
    model_dir = tmp_path / "Qwen3-TTS-12Hz-1.7B-Base"
    model_dir.mkdir()
    (model_dir / "config.json").write_text('{"a": 1}')
    (model_dir / "model.safetensors").write_bytes(b"weights")
    fingerprint = checkpoint_fingerprint(model_dir)
    assert fingerprint == checkpoint_fingerprint(model_dir)
    (model_dir / "model.safetensors").write_bytes(b"heavier-weights")
    assert checkpoint_fingerprint(model_dir) != fingerprint
    with pytest.raises(SpeechConfigurationError):
        checkpoint_fingerprint(tmp_path / "nonexistent")
