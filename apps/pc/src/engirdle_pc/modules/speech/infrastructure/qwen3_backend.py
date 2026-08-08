"""Local Qwen3-TTS runtime boundary.

``LocalQwen3Backend`` owns the two checkpoints (CustomVoice and Base) and
guarantees they are never resident at the same time (design §4.5.1). Heavy
imports (torch / qwen_tts) happen lazily inside ``load_*`` so constructing the
backend — and therefore the application container — stays cheap and importable
in environments without the TTS extra installed.

Tests replace this boundary with a fake; production always uses the local
checkpoints under the configured model root and fails fast when they are
missing.
"""

from __future__ import annotations

import gc
import hashlib
import importlib.util
import json
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from engirdle_pc.shared.infrastructure.hashing import sha256_file

LOGGER = logging.getLogger(__name__)

_REQUIRED_CHECKPOINT_FILES = ("config.json", "model.safetensors")
_FINGERPRINT_FILES = ("config.json", "generation_config.json")

_DTYPES = ("bfloat16", "float16", "float32")


class SpeechConfigurationError(RuntimeError):
    """The Qwen3-TTS runtime (package, checkpoints, device) is not usable."""


class SpeechGenerationError(RuntimeError):
    """The model failed to produce speech for a request."""


@dataclass(frozen=True)
class GeneratedWaveform:
    """Mono float samples in [-1, 1] plus their sample rate."""

    samples: Any  # numpy.ndarray, kept opaque so tests need no numpy
    sample_rate_hz: int


class Qwen3TtsBackend(Protocol):
    def load_custom_voice(self) -> None: ...

    def load_base(self) -> None: ...

    def unload(self) -> None: ...

    def supported_speakers(self) -> tuple[str, ...]: ...

    def set_seed(self, seed: int) -> None: ...

    def generate_custom_voice(
        self,
        *,
        text: str,
        language: str,
        speaker: str,
        instruct: str,
        max_new_tokens: int,
    ) -> GeneratedWaveform: ...

    def create_voice_clone_prompt(
        self, *, ref_audio_path: Path, ref_text: str
    ) -> object: ...

    def generate_voice_clone(
        self,
        *,
        text: str,
        language: str,
        voice_clone_prompt: object,
        max_new_tokens: int,
    ) -> GeneratedWaveform: ...


def tts_package_available() -> bool:
    """Cheap availability probe that avoids importing torch/qwen_tts eagerly."""
    return importlib.util.find_spec("qwen_tts") is not None


def checkpoint_fingerprint(model_dir: Path) -> str:
    """Stable identity hash for a local checkpoint directory.

    Covers the config files' contents and the weight files' names and sizes,
    so it is cheap (no multi-GB hashing) yet detects replacement or corruption
    of the deployment. Raises ``SpeechConfigurationError`` when required files
    are missing.
    """
    missing = [
        name for name in _REQUIRED_CHECKPOINT_FILES if not (model_dir / name).is_file()
    ]
    if missing:
        raise SpeechConfigurationError(
            f"checkpoint {model_dir} is missing required files: {', '.join(missing)}"
        )
    payload: dict[str, Any] = {"directory": model_dir.name, "files": {}}
    for name in _FINGERPRINT_FILES:
        path = model_dir / name
        if path.is_file():
            payload["files"][name] = sha256_file(path)
    weights = []
    for path in sorted(model_dir.glob("*.safetensors")):
        weights.append({"name": path.name, "size": path.stat().st_size})
    payload["weights"] = weights
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def model_identity(hub_id: str, model_dir: Path) -> str:
    return f"{hub_id}@local:{checkpoint_fingerprint(model_dir)[:12]}"


class LocalQwen3Backend:
    """Qwen3-TTS backend over local checkpoints, one model resident at a time."""

    def __init__(
        self,
        *,
        custom_voice_dir: Path,
        base_dir: Path,
        device: str,
        dtype: str,
        attn_implementation: str,
    ) -> None:
        if dtype not in _DTYPES:
            raise SpeechConfigurationError(
                f"unsupported speech dtype {dtype!r}; choose one of {_DTYPES}"
            )
        self._custom_voice_dir = custom_voice_dir
        self._base_dir = base_dir
        self._device = device
        self._dtype = dtype
        self._attn_implementation = attn_implementation
        self._model: Any = None
        self._loaded_kind: str | None = None

    def load_custom_voice(self) -> None:
        self._load("custom_voice", self._custom_voice_dir)

    def load_base(self) -> None:
        self._load("base", self._base_dir)

    def unload(self) -> None:
        if self._model is None:
            return
        kind = self._loaded_kind
        self._model = None
        self._loaded_kind = None
        # HF models tend to hold reference cycles; collect before asking CUDA
        # for the cache back so the checkpoint is actually released.
        gc.collect()
        try:
            import torch

            if torch.cuda.is_available():
                torch.cuda.empty_cache()
        except ImportError:
            pass
        LOGGER.info("qwen3-tts model unloaded", extra={"model_kind": kind})

    def supported_speakers(self) -> tuple[str, ...]:
        model = self._require_model("custom_voice")
        return tuple(str(name) for name in model.get_supported_speakers())

    def set_seed(self, seed: int) -> None:
        torch = self._import_torch()
        torch.manual_seed(seed)
        if torch.cuda.is_available():
            torch.cuda.manual_seed_all(seed)

    def generate_custom_voice(
        self,
        *,
        text: str,
        language: str,
        speaker: str,
        instruct: str,
        max_new_tokens: int,
    ) -> GeneratedWaveform:
        model = self._require_model("custom_voice")
        try:
            wavs, sample_rate = model.generate_custom_voice(
                text=text,
                language=language,
                speaker=speaker,
                instruct=instruct,
                max_new_tokens=max_new_tokens,
            )
        except Exception as error:
            raise SpeechGenerationError(
                f"custom-voice generation failed: {type(error).__name__}: {error}"
            ) from error
        return GeneratedWaveform(samples=wavs[0], sample_rate_hz=int(sample_rate))

    def create_voice_clone_prompt(
        self, *, ref_audio_path: Path, ref_text: str
    ) -> object:
        model = self._require_model("base")
        try:
            return model.create_voice_clone_prompt(
                ref_audio=str(ref_audio_path),
                ref_text=ref_text,
                x_vector_only_mode=False,
            )
        except Exception as error:
            raise SpeechGenerationError(
                f"voice clone prompt creation failed: {type(error).__name__}: {error}"
            ) from error

    def generate_voice_clone(
        self,
        *,
        text: str,
        language: str,
        voice_clone_prompt: object,
        max_new_tokens: int,
    ) -> GeneratedWaveform:
        model = self._require_model("base")
        try:
            wavs, sample_rate = model.generate_voice_clone(
                text=text,
                language=language,
                voice_clone_prompt=voice_clone_prompt,
                max_new_tokens=max_new_tokens,
            )
        except Exception as error:
            raise SpeechGenerationError(
                f"voice clone generation failed: {type(error).__name__}: {error}"
            ) from error
        return GeneratedWaveform(samples=wavs[0], sample_rate_hz=int(sample_rate))

    # -- internals --------------------------------------------------------

    def _load(self, kind: str, model_dir: Path) -> None:
        if self._loaded_kind == kind:
            return
        self.unload()
        checkpoint_fingerprint(model_dir)  # fail fast on a broken checkpoint
        torch = self._import_torch()
        try:
            from qwen_tts import Qwen3TTSModel
        except ImportError as error:
            raise SpeechConfigurationError(
                "the qwen-tts package is not installed; "
                "run `uv sync --extra tts` in apps/pc"
            ) from error
        dtype = getattr(torch, self._dtype)
        LOGGER.info(
            "loading qwen3-tts checkpoint",
            extra={
                "model_kind": kind,
                "device": self._device,
                "dtype": self._dtype,
                "attn": self._attn_implementation,
            },
        )
        try:
            self._model = Qwen3TTSModel.from_pretrained(
                str(model_dir),
                device_map=self._device,
                dtype=dtype,
                attn_implementation=self._attn_implementation,
            )
        except Exception as error:
            raise SpeechConfigurationError(
                f"failed to load checkpoint {model_dir}: "
                f"{type(error).__name__}: {error}"
            ) from error
        self._loaded_kind = kind

    def _require_model(self, expected_kind: str) -> Any:
        if self._model is None or self._loaded_kind != expected_kind:
            raise SpeechConfigurationError(
                f"the {expected_kind} checkpoint is not loaded; call load_*() first"
            )
        return self._model

    @staticmethod
    def _import_torch() -> Any:
        try:
            import torch
        except ImportError as error:
            raise SpeechConfigurationError(
                "torch is not installed; run `uv sync --extra tts` in apps/pc"
            ) from error
        return torch
