"""CustomVoice anchor candidate engine (design §4.5.1).

Generates audition WAVs for one speaker / anchor-text / instruct combination,
one seed per candidate. The CustomVoice checkpoint is loaded for the batch and
unloaded afterwards so it never stays resident next to the Base checkpoint.
"""

from __future__ import annotations

import logging
import threading
from pathlib import Path

from engirdle_pc.modules.speech.application.voice_ports import (
    GeneratedAnchor,
    SpeakerInfo,
)
from engirdle_pc.modules.speech.domain.models import InvalidAnchorRequest
from engirdle_pc.modules.speech.infrastructure.qwen3_backend import (
    Qwen3TtsBackend,
    SpeechGenerationError,
    checkpoint_fingerprint,
    model_identity,
)
from engirdle_pc.shared.infrastructure.hashing import sha256_file

LOGGER = logging.getLogger(__name__)

CUSTOM_VOICE_HUB_ID = "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"

# English-native speakers from the CustomVoice model card; validated against
# the loaded checkpoint before generation.
ENGLISH_SPEAKERS: tuple[SpeakerInfo, ...] = (
    SpeakerInfo("Ryan", "Dynamic male voice with strong rhythmic drive."),
    SpeakerInfo("Aiden", "Sunny American male voice with a clear midrange."),
)

ANCHOR_LANGUAGE = "English"


class Qwen3AnchorEngine:
    def __init__(
        self,
        backend: Qwen3TtsBackend,
        *,
        custom_voice_dir: Path,
        max_new_tokens: int,
    ) -> None:
        self._backend = backend
        self._custom_voice_dir = custom_voice_dir
        self.max_new_tokens = max_new_tokens
        # Admin endpoints run on a thread pool sharing this engine: candidate
        # generation mutates process-global RNG (set_seed) and the single
        # resident checkpoint, so batches must be strictly serialized.
        self._lock = threading.Lock()

    @property
    def model_fingerprint(self) -> str:
        return checkpoint_fingerprint(self._custom_voice_dir)

    @property
    def custom_voice_model(self) -> str:
        return model_identity(CUSTOM_VOICE_HUB_ID, self._custom_voice_dir)

    def english_speakers(self) -> tuple[SpeakerInfo, ...]:
        return ENGLISH_SPEAKERS

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
        with self._lock:
            return self._generate_candidates(
                speaker=speaker,
                anchor_text=anchor_text,
                instruct=instruct,
                seed=seed,
                count=count,
                target_dir=target_dir,
            )

    def _generate_candidates(
        self,
        *,
        speaker: str,
        anchor_text: str,
        instruct: str,
        seed: int,
        count: int,
        target_dir: Path,
    ) -> tuple[GeneratedAnchor, ...]:
        self._backend.load_custom_voice()
        try:
            supported = self._backend.supported_speakers()
            # The checkpoint reports lowercase ids ("ryan"); the public
            # vocabulary uses display names ("Ryan"). Map to the canonical
            # checkpoint id before generation.
            canonical = next(
                (name for name in supported if name.lower() == speaker.lower()),
                None,
            )
            if canonical is None:
                raise InvalidAnchorRequest(
                    f"speaker {speaker!r} is not served by the checkpoint "
                    f"(supported: {', '.join(supported)})"
                )
            target_dir.mkdir(parents=True, exist_ok=False)
            generated: list[GeneratedAnchor] = []
            for index in range(count):
                candidate_seed = seed + index
                self._backend.set_seed(candidate_seed)
                wave = self._backend.generate_custom_voice(
                    text=anchor_text,
                    language=ANCHOR_LANGUAGE,
                    speaker=canonical,
                    instruct=instruct,
                    max_new_tokens=self.max_new_tokens,
                )
                sample_count = len(wave.samples)
                if sample_count == 0 or wave.sample_rate_hz <= 0:
                    raise SpeechGenerationError(
                        f"candidate {index} came back empty from the checkpoint"
                    )
                wav_path = target_dir / f"candidate_{index}.wav"
                _write_wav(wav_path, wave.samples, wave.sample_rate_hz)
                duration_ms = sample_count * 1000 // wave.sample_rate_hz
                generated.append(
                    GeneratedAnchor(
                        candidate_index=index,
                        seed=candidate_seed,
                        wav_path=wav_path,
                        sha256=sha256_file(wav_path),
                        duration_ms=duration_ms,
                        sample_rate_hz=wave.sample_rate_hz,
                    )
                )
                LOGGER.info(
                    "anchor candidate generated",
                    extra={
                        "speaker": speaker,
                        "candidate_index": index,
                        "seed": candidate_seed,
                        "duration_ms": duration_ms,
                        "sample_rate_hz": wave.sample_rate_hz,
                    },
                )
            return tuple(generated)
        finally:
            self._backend.unload()


def _write_wav(path: Path, samples: object, sample_rate_hz: int) -> None:
    try:
        import soundfile as sf
    except ImportError as error:
        raise SpeechGenerationError(
            "soundfile is not installed; run `uv sync --extra tts` in apps/pc"
        ) from error
    sf.write(str(path), samples, sample_rate_hz, subtype="PCM_16")
