"""Qwen3-TTS sentence speech adapter (design §4.5.2).

Implements the ``SpeechAdapter`` protocol against the local Base checkpoint:
one reusable voice-clone prompt per confirmed voice profile revision, then a
batched ``generate_voice_clone`` calls with ``language="English"``. The
CustomVoice checkpoint is never used here — it only creates anchor candidates
through ``Qwen3AnchorEngine``.

This module stays importable without the ``tts`` extra (torch / numpy /
qwen-tts): all heavy imports happen lazily inside functions, so the container
can always wire the real adapter and fail fast only when it is exercised.
"""

from __future__ import annotations

import hashlib
import json
import logging
import math
import time
from array import array
from pathlib import Path
from typing import Any

from engirdle_pc.modules.speech.application.ports import (
    SPEECH_BATCHING,
    SentenceSpeech,
    SpeechRequest,
    VoiceProfileRef,
)
from engirdle_pc.modules.speech.application.service import InvalidSpeechResult
from engirdle_pc.modules.speech.application.voice_ports import VoiceProfileStore
from engirdle_pc.modules.speech.domain.models import (
    VoiceProfile,
    VoiceProfileNotConfigured,
)
from engirdle_pc.modules.speech.infrastructure.qwen3_backend import (
    Qwen3TtsBackend,
    SpeechConfigurationError,
    checkpoint_fingerprint,
    model_identity,
    tts_package_available,
)
from engirdle_pc.shared.infrastructure.hashing import sha256_file

LOGGER = logging.getLogger(__name__)

BASE_HUB_ID = "Qwen/Qwen3-TTS-12Hz-1.7B-Base"
CUSTOM_VOICE_HUB_ID = "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"

CLONE_LANGUAGE = "English"
GENERATION_CONFIG_VERSION = "qwen3-clone@v2"
SAMPLE_RATE_HZ = 24_000


class Qwen3SpeechAdapter:
    def __init__(
        self,
        profiles: VoiceProfileStore,
        backend: Qwen3TtsBackend,
        *,
        custom_voice_model_dir: Path,
        base_model_dir: Path,
        seed: int,
        max_new_tokens: int,
        batch_size: int = 4,
        sample_rate_hz: int = SAMPLE_RATE_HZ,
    ) -> None:
        if batch_size < 1:
            raise SpeechConfigurationError("speech batch size must be at least 1")
        self._batch_size = batch_size
        self._profiles = profiles
        self._backend = backend
        self._custom_voice_model_dir = custom_voice_model_dir
        self._base_model_dir = base_model_dir
        self._seed = seed
        self._max_new_tokens = max_new_tokens
        self._sample_rate_hz = sample_rate_hz
        self._prompt_key: tuple[str, int, str] | None = None
        self._prompt: object = None

    @property
    def batch_size(self) -> int:
        return self._batch_size

    @property
    def name(self) -> str:
        return "qwen3-tts"

    @property
    def custom_voice_model(self) -> str:
        return model_identity(CUSTOM_VOICE_HUB_ID, self._custom_voice_model_dir)

    @property
    def base_model(self) -> str:
        return model_identity(BASE_HUB_ID, self._base_model_dir)

    @property
    def generation_config_id(self) -> str:
        payload = json.dumps(
            {
                "seed": self._seed,
                "max_new_tokens": self._max_new_tokens,
                "sample_rate_hz": self._sample_rate_hz,
                "batch_size": self._batch_size,
                "batching": SPEECH_BATCHING,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()[:12]
        return f"{GENERATION_CONFIG_VERSION}:{digest}"

    @property
    def voice_profile(self) -> VoiceProfileRef:
        profile = self._require_active_profile()
        return VoiceProfileRef(
            voice_profile_id=profile.voice_profile_id,
            revision=profile.revision,
            anchor_sha256=profile.anchor_sha256,
        )

    def verify_setup(self) -> None:
        """Fail fast when the runtime cannot serve speech at all."""
        if not tts_package_available():
            raise SpeechConfigurationError(
                "the qwen-tts package is not installed; "
                "run `uv sync --extra tts` in apps/pc"
            )
        checkpoint_fingerprint(self._custom_voice_model_dir)
        checkpoint_fingerprint(self._base_model_dir)

    def synthesize(
        self, sentence_id: str, text: str, target_dir: Path
    ) -> SentenceSpeech:
        return self.synthesize_batch((SpeechRequest(sentence_id, text),), target_dir)[0]

    def synthesize_batch(
        self, requests: tuple[SpeechRequest, ...], target_dir: Path
    ) -> tuple[SentenceSpeech, ...]:
        if not requests:
            return ()
        if len(requests) > self._batch_size:
            raise SpeechConfigurationError("speech batch exceeds configured batch size")
        if len({request.sentence_id for request in requests}) != len(requests):
            raise InvalidSpeechResult("speech batch contains duplicate sentence IDs")
        profile = self._require_active_profile()
        self._backend.load_base()
        prompt = self._prompt_for(profile)
        self._backend.set_seed(self._seed)
        started = time.monotonic()
        waves = self._backend.generate_voice_clone_batch(
            texts=tuple(request.text for request in requests),
            language=CLONE_LANGUAGE,
            voice_clone_prompt=prompt,
            max_new_tokens=self._max_new_tokens,
        )
        if len(waves) != len(requests):
            raise InvalidSpeechResult("model returned a different number of waveforms")
        # Validate every waveform before writing any part of this batch.
        pcms = tuple(
            _to_int16_pcm(wave.samples, wave.sample_rate_hz, self._sample_rate_hz)
            for wave in waves
        )
        target_dir.mkdir(parents=True, exist_ok=True)
        results: list[SentenceSpeech] = []
        for request, pcm in zip(requests, pcms, strict=True):
            pcm_path = target_dir / f"{request.sentence_id}.pcm"
            pending_path = pcm_path.with_suffix(".pcm.tmp")
            pending_path.write_bytes(pcm)
            pending_path.replace(pcm_path)
            results.append(SentenceSpeech(
                sentence_id=request.sentence_id, pcm_path=pcm_path,
                sample_rate_hz=self._sample_rate_hz, sample_count=len(pcm) // 2,
            ))
        LOGGER.info(
            "qwen3-tts synthesized batch",
            extra={
                "sentence_ids": [result.sentence_id for result in results],
                "batch_size": len(results),
                "duration_ms": sum(result.sample_count for result in results)
                * 1000 // self._sample_rate_hz,
                "elapsed_ms": int((time.monotonic() - started) * 1000),
                "voice_profile": f"{profile.voice_profile_id}@{profile.revision}",
            },
        )
        return tuple(results)

    # -- internals --------------------------------------------------------

    def _require_active_profile(self) -> VoiceProfile:
        profile = self._profiles.active_profile()
        if profile is None:
            raise VoiceProfileNotConfigured(
                "no confirmed voice profile; create and confirm an anchor first"
            )
        return profile

    def _prompt_for(self, profile: VoiceProfile) -> object:
        """Build the clone prompt once per voice profile revision and reuse it."""
        key = (profile.voice_profile_id, profile.revision, profile.anchor_sha256)
        if self._prompt_key == key and self._prompt is not None:
            return self._prompt
        if not profile.anchor_wav_path.is_file():
            raise SpeechConfigurationError(
                f"anchor WAV for {profile.voice_profile_id}@{profile.revision} "
                f"is missing: {profile.anchor_wav_path}"
            )
        actual_sha256 = sha256_file(profile.anchor_wav_path)
        if actual_sha256 != profile.anchor_sha256:
            raise SpeechConfigurationError(
                f"anchor WAV hash mismatch for "
                f"{profile.voice_profile_id}@{profile.revision}: expected "
                f"{profile.anchor_sha256[:12]}…, got {actual_sha256[:12]}…"
            )
        self._prompt = self._backend.create_voice_clone_prompt(
            ref_audio_path=profile.anchor_wav_path,
            ref_text=profile.anchor_text,
        )
        self._prompt_key = key
        LOGGER.info(
            "qwen3-tts voice clone prompt created",
            extra={"voice_profile": f"{profile.voice_profile_id}@{profile.revision}"},
        )
        return self._prompt


def _to_int16_pcm(
    samples: Any, source_sample_rate_hz: int, expected_sample_rate_hz: int
) -> bytes:
    """Validate the model output and convert it to mono s16le PCM bytes.

    Deliberately implemented with the standard library only: the sequence
    protocol works for both the model's numpy arrays and plain test fixtures,
    and keeps this adapter importable without the ``tts`` extra installed.
    """
    if source_sample_rate_hz != expected_sample_rate_hz:
        raise InvalidSpeechResult(
            f"model returned {source_sample_rate_hz} Hz, expected "
            f"{expected_sample_rate_hz} Hz; refusing to resample silently"
        )
    ndim = getattr(samples, "ndim", 1)
    if ndim == 2:
        shape = getattr(samples, "shape", (0, 0))
        if shape[1] != 1:
            raise InvalidSpeechResult(
                f"model output must be mono, got shape {tuple(shape)}"
            )
        samples = samples.reshape(-1)
    elif ndim != 1:
        raise InvalidSpeechResult("model output must be a mono waveform")

    values = [float(sample) for sample in samples]
    if not values:
        raise InvalidSpeechResult("model returned empty audio")
    if not all(math.isfinite(value) for value in values):
        raise InvalidSpeechResult("model returned non-finite samples")
    if max(abs(value) for value in values) == 0.0:
        raise InvalidSpeechResult("model returned silent audio")
    pcm = array(
        "h",
        (round(max(-1.0, min(1.0, value)) * 32_767) for value in values),
    )
    return pcm.tobytes()


def build_qwen3_speech_adapter(
    settings: Any,
    profiles: VoiceProfileStore,
    *,
    backend: Qwen3TtsBackend | None = None,
) -> Qwen3SpeechAdapter:
    """Wire the production adapter from settings (model loading stays lazy)."""
    if backend is None:
        from engirdle_pc.modules.speech.infrastructure.qwen3_backend import (
            LocalQwen3Backend,
        )

        backend = LocalQwen3Backend(
            custom_voice_dir=settings.custom_voice_model_dir,
            base_dir=settings.base_model_dir,
            device=settings.speech_device,
            dtype=settings.speech_dtype,
            attn_implementation=settings.speech_attn_implementation,
        )
    return Qwen3SpeechAdapter(
        profiles,
        backend,
        custom_voice_model_dir=settings.custom_voice_model_dir,
        base_model_dir=settings.base_model_dir,
        seed=settings.speech_seed,
        max_new_tokens=settings.speech_max_new_tokens,
        batch_size=settings.speech_batch_size,
    )
