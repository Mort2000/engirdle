from __future__ import annotations

import math
from array import array
from pathlib import Path

from engirdle_pc.modules.speech.application.ports import SentenceSpeech, VoiceProfileRef
from engirdle_pc.shared.infrastructure.hashing import sha256_text


class StubSpeechAdapter:
    """Deterministic audible-tone stub; it does not load Qwen3-TTS or `.tts`."""

    name = "stub"
    custom_voice_model = "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice@stub"
    base_model = "Qwen/Qwen3-TTS-12Hz-1.7B-Base@stub"
    generation_config_id = "tone-pcm@v1"
    sample_rate_hz = 24_000

    def __init__(self) -> None:
        self._voice_profile = VoiceProfileRef(
            voice_profile_id="stub-voice-profile",
            revision=1,
            anchor_sha256=sha256_text("engirdle deterministic speech stub anchor"),
        )

    @property
    def voice_profile(self) -> VoiceProfileRef:
        return self._voice_profile

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
