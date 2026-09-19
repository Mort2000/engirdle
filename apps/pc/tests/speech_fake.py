"""Test doubles for the speech boundary.

``StubSpeechAdapter`` is the deterministic audible-tone fake used by worker and
acceptance tests so they can drive the production pipeline without GPU, model
weights or the ``tts`` extra. Production entrypoints always use the real
Qwen3-TTS adapter; this file lives in tests on purpose.
"""

from __future__ import annotations

import math
import wave
from array import array
from pathlib import Path

from engirdle_pc.modules.speech.application.ports import (
    SentenceSpeech,
    SpeechRequest,
    VoiceProfileRef,
)
from engirdle_pc.modules.speech.application.voice_ports import (
    GeneratedAnchor,
    SpeakerInfo,
)
from engirdle_pc.modules.speech.infrastructure.qwen3_backend import GeneratedWaveform
from engirdle_pc.shared.domain.hashing import sha256_text
from engirdle_pc.shared.infrastructure.hashing import sha256_file


class StubSpeechAdapter:
    """Deterministic audible-tone stub; it never loads Qwen3-TTS or `.tts`."""

    name = "stub"
    custom_voice_model = "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice@stub"
    base_model = "Qwen/Qwen3-TTS-12Hz-1.7B-Base@stub"
    generation_config_id = "tone-pcm@v1"
    sample_rate_hz = 24_000

    def __init__(self, batch_size: int = 4) -> None:
        self.batch_size = batch_size
        self._voice_profile = VoiceProfileRef(
            voice_profile_id="stub-voice-profile",
            revision=1,
            anchor_sha256=sha256_text("engirdle deterministic speech stub anchor"),
        )

    @property
    def voice_profile(self) -> VoiceProfileRef:
        return self._voice_profile

    def set_voice_profile(self, voice_profile: VoiceProfileRef) -> None:
        """Test hook: simulate confirming/activating a different profile."""
        self._voice_profile = voice_profile

    def verify_setup(self) -> None:
        """The stub has no external dependencies; setup always succeeds."""

    def synthesize(self, sentence_id: str, text: str, target_dir: Path) -> SentenceSpeech:
        target_dir.mkdir(parents=True, exist_ok=True)
        duration_seconds = min(2.0, max(0.45, len(text) / 24.0))
        sample_count = round(duration_seconds * self.sample_rate_hz)
        frequency = 330 + (sum(text.encode("utf-8")) % 120)
        samples = array(
            "h",
            (
                round(5_500 * math.sin(2 * math.pi * frequency * index / self.sample_rate_hz))
                for index in range(sample_count)
            ),
        )
        path = target_dir / f"{sentence_id}.pcm"
        path.write_bytes(samples.tobytes())
        return SentenceSpeech(sentence_id, path, self.sample_rate_hz, sample_count)

    def synthesize_batch(
        self, requests: tuple[SpeechRequest, ...], target_dir: Path
    ) -> tuple[SentenceSpeech, ...]:
        return tuple(self.synthesize(r.sentence_id, r.text, target_dir) for r in requests)


def _float_samples(sample_count: int, amplitude: float = 0.3) -> list[float]:
    return [
        amplitude * math.sin(2 * math.pi * 220 * index / 24_000)
        for index in range(sample_count)
    ]


class FakeQwen3Backend:
    """Records calls and returns deterministic float waveforms."""

    def __init__(self, sample_rate_hz: int = 24_000, sample_count: int = 4_800) -> None:
        self.sample_rate_hz = sample_rate_hz
        self.sample_count = sample_count
        self.loaded_kind: str | None = None
        self.unload_calls = 0
        self.seeds: list[int] = []
        self.custom_voice_calls: list[dict[str, object]] = []
        self.clone_prompt_calls: list[dict[str, object]] = []
        self.voice_clone_calls: list[dict[str, object]] = []
        self.waveform: object = None  # override to inject invalid output

    def load_custom_voice(self) -> None:
        self.loaded_kind = "custom_voice"

    def load_base(self) -> None:
        self.loaded_kind = "base"

    def unload(self) -> None:
        self.loaded_kind = None
        self.unload_calls += 1

    def supported_speakers(self) -> tuple[str, ...]:
        # Mirrors the real checkpoint, which reports lowercase speaker ids.
        return ("ryan", "aiden")

    def set_seed(self, seed: int) -> None:
        self.seeds.append(seed)

    def generate_custom_voice(
        self,
        *,
        text: str,
        language: str,
        speaker: str,
        instruct: str,
        max_new_tokens: int,
    ) -> GeneratedWaveform:
        self.custom_voice_calls.append(
            {
                "text": text,
                "language": language,
                "speaker": speaker,
                "instruct": instruct,
                "max_new_tokens": max_new_tokens,
            }
        )
        return GeneratedWaveform(
            samples=(
                self.waveform
                if self.waveform is not None
                else _float_samples(self.sample_count)
            ),
            sample_rate_hz=self.sample_rate_hz,
        )

    def create_voice_clone_prompt(
        self, *, ref_audio_path: Path, ref_text: str
    ) -> object:
        self.clone_prompt_calls.append(
            {"ref_audio_path": ref_audio_path, "ref_text": ref_text}
        )
        return {"prompt_for": ref_text}

    def generate_voice_clone(
        self,
        *,
        text: str,
        language: str,
        voice_clone_prompt: object,
        max_new_tokens: int,
    ) -> GeneratedWaveform:
        return self.generate_voice_clone_batch(
            texts=(text,), language=language, voice_clone_prompt=voice_clone_prompt,
            max_new_tokens=max_new_tokens,
        )[0]

    def generate_voice_clone_batch(
        self,
        *,
        texts: tuple[str, ...],
        language: str,
        voice_clone_prompt: object,
        max_new_tokens: int,
    ) -> tuple[GeneratedWaveform, ...]:
        self.voice_clone_calls.append(
            {
                "text": texts[0] if len(texts) == 1 else list(texts),
                "language": language,
                "voice_clone_prompt": voice_clone_prompt,
                "max_new_tokens": max_new_tokens,
            }
        )
        return tuple(GeneratedWaveform(
            samples=(
                self.waveform
                if self.waveform is not None
                else _float_samples(self.sample_count)
            ),
            sample_rate_hz=self.sample_rate_hz,
        ) for _ in texts)


class FakeAnchorEngine:
    """Writes tiny but valid PCM WAV candidates without any model."""

    custom_voice_model = "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice@fake"
    model_fingerprint = "fake-fingerprint"
    max_new_tokens = 2_048

    def __init__(self, sample_rate_hz: int = 24_000) -> None:
        self.sample_rate_hz = sample_rate_hz
        self.calls: list[dict[str, object]] = []
        self.failure: Exception | None = None  # inject server-side failures

    def english_speakers(self) -> tuple[SpeakerInfo, ...]:
        return (
            SpeakerInfo("Ryan", "Dynamic male voice with strong rhythmic drive."),
            SpeakerInfo("Aiden", "Sunny American male voice with a clear midrange."),
        )

    def generate_candidates(
        self,
        *,
        speaker: str,
        anchor_text: str,
        instruct: str,
        seed: int,
        count: int,
        target_dir: Path,
    ) -> tuple[GeneratedAnchor, ...]:
        if self.failure is not None:
            raise self.failure
        self.calls.append(
            {
                "speaker": speaker,
                "anchor_text": anchor_text,
                "instruct": instruct,
                "seed": seed,
                "count": count,
            }
        )
        target_dir.mkdir(parents=True, exist_ok=False)
        generated: list[GeneratedAnchor] = []
        for index in range(count):
            sample_count = self.sample_rate_hz // 2
            wav_path = target_dir / f"candidate_{index}.wav"
            with wave.open(str(wav_path), "wb") as wav_file:
                wav_file.setnchannels(1)
                wav_file.setsampwidth(2)
                wav_file.setframerate(self.sample_rate_hz)
                wav_file.writeframes(
                    array(
                        "h",
                        (
                            round(
                                8_000
                                * math.sin(
                                    2 * math.pi * (200 + index * 50) * i / self.sample_rate_hz
                                )
                            )
                            for i in range(sample_count)
                        ),
                    ).tobytes()
                )
            generated.append(
                GeneratedAnchor(
                    candidate_index=index,
                    seed=seed + index,
                    wav_path=wav_path,
                    sha256=sha256_file(wav_path),
                    duration_ms=sample_count * 1000 // self.sample_rate_hz,
                    sample_rate_hz=self.sample_rate_hz,
                )
            )
        return tuple(generated)
