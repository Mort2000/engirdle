from __future__ import annotations

from pathlib import Path

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


def _repository_root() -> Path:
    return Path(__file__).resolve().parents[5]


def _default_contracts_dir() -> Path:
    repository_contracts = _repository_root() / "contracts"
    if repository_contracts.is_dir():
        return repository_contracts
    return Path(__file__).resolve().parents[1] / "contracts"


class Settings(BaseSettings):
    """Strongly typed process configuration without secret material."""

    model_config = SettingsConfigDict(env_prefix="ENGIRDLE_", frozen=True)

    workspace: Path = Field(default=Path.home() / ".local" / "share" / "engirdle")
    contracts_dir: Path = Field(default_factory=_default_contracts_dir)
    management_host: str = "127.0.0.1"
    management_port: int = 8765
    publisher_host: str = "0.0.0.0"
    publisher_port: int = 8766
    ffmpeg_path: Path | None = None
    sentence_pause_ms: int = 200
    block_pause_ms: int = 500
    # DeepSeek translation provider (non-secret deployment config; the API key
    # itself is injected separately from the environment, never stored here).
    # Thinking mode / reasoning effort are fixed quality baselines, not tunable
    # here, so they cannot drift from the immutable task-config snapshot.
    deepseek_endpoint: str = "https://api.deepseek.com"
    deepseek_model: str = "deepseek-v4-flash"
    deepseek_request_timeout_seconds: float = 120.0
    deepseek_max_retries: int = 3
    # Qwen3-TTS local speech runtime (non-secret deployment config). Checkpoints
    # live under the app-managed model root, never inside the repository.
    speech_model_root: Path | None = None
    speech_device: str = "cuda:0"
    speech_dtype: str = "bfloat16"
    speech_attn_implementation: str = "sdpa"
    speech_seed: int = 0
    speech_max_new_tokens: int = 2048
    speech_anchor_candidates: int = 3

    @field_validator("management_host")
    @classmethod
    def management_must_be_loopback(cls, value: str) -> str:
        if value not in {"127.0.0.1", "::1", "localhost"}:
            raise ValueError("management_host must be a loopback address")
        return value

    @property
    def database_path(self) -> Path:
        return self.workspace / "app.db"

    @property
    def public_dir(self) -> Path:
        return self.workspace / "public"

    @property
    def resolved_speech_model_root(self) -> Path:
        return self.speech_model_root or (self.workspace / "models")

    @property
    def custom_voice_model_dir(self) -> Path:
        return self.resolved_speech_model_root / "Qwen3-TTS-12Hz-1.7B-CustomVoice"

    @property
    def base_model_dir(self) -> Path:
        return self.resolved_speech_model_root / "Qwen3-TTS-12Hz-1.7B-Base"
