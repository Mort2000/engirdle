"""Typed errors for the DeepSeek translation adapter.

The adapter, its HTTP client and the worker all exchange these typed errors
instead of raw provider exceptions. ``error_code`` recorded on a failed job is
the class name, so keep names stable and self-describing (see design §10 and
the ``context_limit_exceeded`` requirement in §4.4.1).
"""

from __future__ import annotations


class TranslationError(Exception):
    """Base class for all translation failures."""


class DeepSeekConfigurationError(TranslationError):
    """The adapter cannot run: API key or official endpoint not configured."""


class TranslationAuthError(TranslationError):
    """The provider rejected the API key (HTTP 401/403)."""


class TranslationQuotaError(TranslationError):
    """The account has insufficient balance (HTTP 402)."""


class TranslationRateLimitError(TranslationError):
    """The provider is throttling requests (HTTP 429). Transient."""


class TranslationServerError(TranslationError):
    """The provider returned a server-side or connection error (5xx/network).
    Transient."""


class TranslationTimeoutError(TranslationError):
    """A request to the provider timed out. Transient."""


class TranslationContextLimitError(TranslationError):
    """The accumulated logical session exceeds the model context window."""


class TranslationProtocolError(TranslationError):
    """The model returned a response that fails schema/length validation."""


_TRANSIENT_TYPES: tuple[type[TranslationError], ...] = (
    TranslationRateLimitError,
    TranslationServerError,
    TranslationTimeoutError,
)


def is_transient(error: TranslationError) -> bool:
    """Whether a failure may succeed on a bounded retry within one request."""
    return isinstance(error, _TRANSIENT_TYPES)
