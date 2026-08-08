"""OpenAI-compatible chat client for DeepSeek, behind an injectable port.

DeepSeek exposes an OpenAI-compatible API, so we reuse the official ``openai``
SDK (``OpenAI(base_url=OFFICIAL_ENDPOINT, ...)``) rather than a hand-rolled HTTP
client. Provider exceptions are mapped to the typed errors in ``deepseek_errors``
via the pure ``classify_api_error`` helper. Tests inject a fake client that
returns scripted ``CompletionResult`` values or raises typed errors directly.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Protocol, cast

from openai import APIConnectionError, APIError, APITimeoutError, OpenAI
from openai.types.chat import ChatCompletionMessageParam

from engirdle_pc.modules.translation.infrastructure.deepseek_errors import (
    DeepSeekConfigurationError,
    TranslationAuthError,
    TranslationContextLimitError,
    TranslationError,
    TranslationProtocolError,
    TranslationQuotaError,
    TranslationRateLimitError,
    TranslationServerError,
    TranslationTimeoutError,
)

OFFICIAL_ENDPOINT = "https://api.deepseek.com"

# Substrings in a 400/413 message that indicate the context window is exhausted.
# Kept specific so ordinary 400s (e.g. "messages length must be >= 1") are not
# misclassified as a context-limit failure.
_CONTEXT_LIMIT_MARKERS = (
    "context length",
    "context window",
    "maximum context",
    "exceeds the context",
    "input length exceeds",
    "too long",
)


@dataclass(frozen=True)
class CompletionUsage:
    prompt_tokens: int
    completion_tokens: int
    reasoning_tokens: int


@dataclass(frozen=True)
class CompletionResult:
    content: str
    finish_reason: str
    request_id: str
    usage: CompletionUsage | None


class DeepSeekApiClient(Protocol):
    """Minimal client port the adapter depends on (injectable for tests)."""

    def create_chat_completion(
        self,
        *,
        model: str,
        messages: list[dict[str, str]],
        extra_body: dict[str, Any],
        timeout: float,
    ) -> CompletionResult:
        """Complete a chat turn. May raise a typed ``TranslationError``."""

    def list_models(self, *, timeout: float) -> list[str]:
        """Return available model ids. Used to verify API access."""


def classify_api_error(
    *,
    status_code: int | None = None,
    message: str = "",
    timeout: bool = False,
    connection: bool = False,
) -> Exception:
    """Map a provider failure to a typed translation error (pure, no SDK state)."""
    if timeout:
        return _err(TranslationTimeoutError, "request timed out", status_code, message)
    if connection:
        return _err(TranslationServerError, "connection to provider failed", status_code, message)
    if status_code is None:
        return _err(TranslationServerError, "unknown provider error", status_code, message)
    lowered = message.lower()
    if status_code in (401, 403):
        return _err(TranslationAuthError, "provider rejected the API key", status_code, message)
    if status_code == 402:
        return _err(TranslationQuotaError, "insufficient account balance", status_code, message)
    if status_code == 429:
        return _err(TranslationRateLimitError, "provider rate limit", status_code, message)
    if status_code in (400, 413) and any(marker in lowered for marker in _CONTEXT_LIMIT_MARKERS):
        return _err(
            TranslationContextLimitError,
            "accumulated context exceeds the model window",
            status_code,
            message,
        )
    if 500 <= status_code < 600:
        return _err(TranslationServerError, "provider server error", status_code, message)
    return _err(TranslationProtocolError, "provider rejected the request", status_code, message)


def _err(
    error_type: type[TranslationError],
    summary: str,
    status_code: int | None,
    message: str,
) -> TranslationError:
    return error_type(_describe(summary, status_code, message))


def _describe(summary: str, status_code: int | None, message: str) -> str:
    detail = message.strip()
    suffix = f" — {detail}" if detail else ""
    if status_code is None:
        return f"{summary}{suffix}"
    return f"{summary} (HTTP {status_code}){suffix}"


class OpenAIDeepSeekApiClient:
    """Production client wrapping the official ``openai`` SDK against DeepSeek."""

    def __init__(self, api_key: str, *, base_url: str, timeout: float) -> None:
        # Defense-in-depth for design §10: the real key must never reach an
        # arbitrary URL. Enforced at the factory too, but the client is the last
        # gate regardless of how it was constructed.
        if base_url != OFFICIAL_ENDPOINT:
            raise DeepSeekConfigurationError(
                f"deepseek client refuses non-official endpoint {base_url!r}"
            )
        self._client = OpenAI(api_key=api_key, base_url=base_url, timeout=timeout)

    def create_chat_completion(
        self,
        *,
        model: str,
        messages: list[dict[str, str]],
        extra_body: dict[str, Any],
        timeout: float,
    ) -> CompletionResult:
        try:
            response = self._client.chat.completions.create(
                model=model,
                messages=cast("list[ChatCompletionMessageParam]", messages),
                extra_body=extra_body,
                timeout=timeout,
            )
        except APIError as error:
            raise _map_api_error(error) from error
        if not response.choices:
            raise TranslationProtocolError("provider returned no completion choices")
        choice = response.choices[0]
        return CompletionResult(
            content=choice.message.content or "",
            finish_reason=choice.finish_reason or "",
            request_id=response.id,
            usage=_extract_usage(response.usage),
        )

    def list_models(self, *, timeout: float) -> list[str]:
        try:
            response = self._client.models.list(timeout=timeout)
        except APIError as error:
            raise _map_api_error(error) from error
        return [model.id for model in response.data]


def _map_api_error(error: APIError) -> Exception:
    return classify_api_error(
        status_code=getattr(error, "status_code", None),
        message=str(error),
        timeout=isinstance(error, APITimeoutError),
        connection=isinstance(error, APIConnectionError),
    )


def _extract_usage(usage: Any) -> CompletionUsage | None:
    if usage is None:
        return None
    reasoning = 0
    details = getattr(usage, "completion_tokens_details", None)
    if details is not None:
        reasoning = getattr(details, "reasoning_tokens", None) or 0
    return CompletionUsage(
        prompt_tokens=getattr(usage, "prompt_tokens", 0) or 0,
        completion_tokens=getattr(usage, "completion_tokens", 0) or 0,
        reasoning_tokens=reasoning,
    )
