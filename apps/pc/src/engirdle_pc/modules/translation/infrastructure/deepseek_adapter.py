"""DeepSeek translation adapter.

Implements the ``TranslationAdapter`` protocol with the simplified protocol
(design §4.4, as refined): no round-zero acknowledgement; each block is sent as
a bare JSON array of its English sentences and the model returns a same-length
JSON array of Simplified Chinese translations. The full logical session
(system + complete-article context + accepted block turns) is replayed on every
request so terminology stays consistent, with no sliding window or downgrade.

State is reconstructed from a durable per-checkpoint journal, so a worker can
resume a translation session even across a process restart (lease recovery).
"""

from __future__ import annotations

import json
import logging
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any, TypeVar

from pydantic import ValidationError

from engirdle_pc.modules.content.public import ArticleRevision, Block
from engirdle_pc.modules.translation.application.dto import (
    PROMPT_VERSION,
    REASONING_EFFORT,
    THINKING_MODE,
    build_block_request,
    build_source_context,
    build_system_prompt,
    parse_translation_list,
)
from engirdle_pc.modules.translation.application.ports import (
    SentenceTranslation,
    TranslationBatch,
)
from engirdle_pc.modules.translation.infrastructure.chat_client import (
    OFFICIAL_ENDPOINT,
    CompletionResult,
    DeepSeekApiClient,
    OpenAIDeepSeekApiClient,
)
from engirdle_pc.modules.translation.infrastructure.deepseek_errors import (
    DeepSeekConfigurationError,
    TranslationError,
    TranslationProtocolError,
    is_transient,
)
from engirdle_pc.modules.translation.infrastructure.session_journal import (
    TranslationSessionJournal,
)
from engirdle_pc.shared.application.runtime import IdentifierGenerator
from engirdle_pc.shared.domain.hashing import sha256_text

LOGGER = logging.getLogger(__name__)

_DEFAULT_TIMEOUT_SECONDS = 120.0
_DEFAULT_MAX_RETRIES = 3
_DEFAULT_BACKOFF_SECONDS = 0.5

_T = TypeVar("_T")

TRANSLATION_PROVIDER = "deepseek"
TRANSLATION_ADAPTER_NAME = "deepseek"


def _is_retryable(error: TranslationError) -> bool:
    """Transient transport failures and transiently-malformed responses may succeed on retry."""
    return is_transient(error) or isinstance(error, TranslationProtocolError)


def load_deepseek_api_key() -> str | None:
    """Read the DeepSeek API key from the environment (no fallback to a store yet)."""
    import os

    key = os.environ.get("DEEPSEEK_API_KEY")
    return key.strip() if key else None


class DeepSeekTranslationAdapter:
    """Production translation adapter against the DeepSeek OpenAI-compatible API."""

    name = TRANSLATION_ADAPTER_NAME
    provider = TRANSLATION_PROVIDER
    endpoint: str
    model: str

    def __init__(
        self,
        *,
        client: DeepSeekApiClient | None,
        endpoint: str,
        model: str,
        session_dir: Path,
        identifiers: IdentifierGenerator,
        timeout_seconds: float = _DEFAULT_TIMEOUT_SECONDS,
        max_retries: int = _DEFAULT_MAX_RETRIES,
        retry_backoff_seconds: float = _DEFAULT_BACKOFF_SECONDS,
        sleeper: Callable[[float], None] = time.sleep,
        thinking: str = THINKING_MODE,
        reasoning_effort: str = REASONING_EFFORT,
        prompt_version: str = PROMPT_VERSION,
    ) -> None:
        self._client = client
        self.endpoint = endpoint
        self.model = model
        self._thinking = thinking
        self._reasoning_effort = reasoning_effort
        self._session_dir = session_dir
        self._identifiers = identifiers
        self._timeout = timeout_seconds
        self._max_retries = max_retries
        self._retry_backoff_seconds = retry_backoff_seconds
        self._sleeper = sleeper
        self._prompt_version = prompt_version

    def begin(self, revision: ArticleRevision) -> str:
        """Initialize a durable session journal and return its checkpoint id.

        Deliberately makes no network call: the complete-article context is sent
        as part of the first ``translate_block`` request.
        """
        checkpoint_id = self._identifiers.new()
        TranslationSessionJournal.create(
            directory=self._session_dir,
            checkpoint_id=checkpoint_id,
            source_sha256=sha256_text(build_source_context(revision)),
            prompt_version=self._prompt_version,
        )
        return checkpoint_id

    def translate_block(
        self, revision: ArticleRevision, block: Block, checkpoint_id: str
    ) -> TranslationBatch:
        journal = self._load_journal(checkpoint_id)
        self._verify_journal_freshness(journal, revision)
        messages = self._build_messages(revision, block, journal)
        client = self._require_client()

        def attempt() -> tuple[CompletionResult, list[str]]:
            # Validation runs inside the retry loop so a transiently malformed
            # model response (wrong length, fenced, object-wrapped) gets the same
            # bounded retry budget as transport errors, instead of failing the
            # job on the first flaky reply.
            result = client.create_chat_completion(
                model=self.model,
                messages=messages,
                extra_body=self._extra_body(),
                timeout=self._timeout,
            )
            return result, self._validate(result, block)

        result, translations = self._retry_request(attempt)
        # Persist only validated translations; a protocol failure must not pollute
        # the accepted history that subsequent blocks (or a retry) will replay.
        journal.accept_block(block.block_id, translations)
        self._log_usage(block, result)
        return TranslationBatch(
            block_id=block.block_id,
            translations=tuple(
                SentenceTranslation(
                    sentence_id=sentence.sentence_id, text_zh=translations[index]
                )
                for index, sentence in enumerate(block.sentences)
            ),
            request_id=result.request_id,
        )

    def verify_access(self) -> None:
        """Confirm the key works AND the configured model is served by the provider."""
        client = self._require_client()
        models = self._retry_request(lambda: client.list_models(timeout=self._timeout))
        if self.model not in models:
            raise DeepSeekConfigurationError(
                f"model {self.model!r} is not available; provider offers {models}"
            )

    # -- internals --------------------------------------------------------

    def _require_client(self) -> DeepSeekApiClient:
        if self._client is None:
            raise DeepSeekConfigurationError(
                "DEEPSEEK_API_KEY is not configured; the translation adapter cannot run"
            )
        return self._client

    def _load_journal(self, checkpoint_id: str) -> TranslationSessionJournal:
        journal = TranslationSessionJournal.load(self._session_dir, checkpoint_id)
        if journal is None:
            raise TranslationProtocolError(
                f"translation session journal not found for checkpoint {checkpoint_id}"
            )
        return journal

    def _verify_journal_freshness(
        self, journal: TranslationSessionJournal, revision: ArticleRevision
    ) -> None:
        """Reject a journal that does not match this revision / prompt version.

        Guards against checkpoint_id reuse across revisions or a stale journal
        left by an older prompt version after an upgrade.
        """
        expected_source_sha256 = sha256_text(build_source_context(revision))
        if (
            journal.source_sha256 != expected_source_sha256
            or journal.prompt_version != self._prompt_version
        ):
            raise TranslationProtocolError(
                "translation session journal does not match the current revision "
                "or prompt version"
            )

    def _build_messages(
        self,
        revision: ArticleRevision,
        block: Block,
        journal: TranslationSessionJournal,
    ) -> list[dict[str, str]]:
        messages: list[dict[str, str]] = [
            {"role": "system", "content": build_system_prompt()},
            {"role": "user", "content": build_source_context(revision)},
        ]
        reached_block = False
        for prior_block in revision.blocks:
            if prior_block.block_id == block.block_id:
                reached_block = True
                break
            translations = journal.accepted.get(prior_block.block_id)
            if translations is None:
                raise TranslationProtocolError(
                    f"cannot rebuild history: block {prior_block.block_id} precedes "
                    f"{block.block_id} but has no accepted translation"
                )
            messages.append({"role": "user", "content": build_block_request(prior_block)})
            messages.append(
                {
                    "role": "assistant",
                    "content": json.dumps(translations, ensure_ascii=False),
                }
            )
        if not reached_block:
            raise TranslationProtocolError(
                f"block {block.block_id} is not part of revision "
                f"{revision.article_id}/{revision.revision}"
            )
        messages.append({"role": "user", "content": build_block_request(block)})
        return messages

    def _extra_body(self) -> dict[str, Any]:
        return {
            "thinking": {"type": self._thinking},
            "reasoning_effort": self._reasoning_effort,
        }

    def _retry_request(self, operation: Callable[[], _T]) -> _T:
        """Retry transient transport errors and transiently-malformed responses.

        Both rate-limit/server/timeout failures and protocol-validation failures
        (wrong array length, fenced/object-wrapped/empty response) are retried up
        to ``max_retries`` times; non-retryable errors (auth/quota/config) surface
        immediately so the worker can fail the job and let an operator retry.
        """
        attempt = 0
        while True:
            try:
                return operation()
            except TranslationError as error:
                if not _is_retryable(error) or attempt >= self._max_retries:
                    raise
                self._sleeper(min(self._retry_backoff_seconds * (2**attempt), 10.0))
                attempt += 1

    def _validate(self, result: CompletionResult, block: Block) -> list[str]:
        try:
            translations = parse_translation_list(result.content)
        except ValidationError as error:
            raise TranslationProtocolError(
                f"model response for block {block.block_id} is not a JSON array of "
                f"non-empty strings"
            ) from error
        if len(translations) != len(block.sentences):
            raise TranslationProtocolError(
                f"model returned {len(translations)} translations for block "
                f"{block.block_id} which has {len(block.sentences)} sentences"
            )
        return translations

    def _log_usage(self, block: Block, result: CompletionResult) -> None:
        # Structured usage only — never log content, translations or reasoning.
        LOGGER.info(
            "deepseek translated block",
            extra={
                "block_id": block.block_id,
                "request_id": result.request_id,
                "finish_reason": result.finish_reason,
                "usage": (
                    {
                        "prompt_tokens": result.usage.prompt_tokens,
                        "completion_tokens": result.usage.completion_tokens,
                        "reasoning_tokens": result.usage.reasoning_tokens,
                    }
                    if result.usage
                    else None
                ),
            },
        )


def build_deepseek_adapter(
    settings: Any,
    api_key: str | None,
    identifiers: IdentifierGenerator,
) -> DeepSeekTranslationAdapter:
    """Build the production adapter from settings and an explicit API key.

    The endpoint must be the official DeepSeek endpoint (design §10: the real
    key is never sent to an arbitrary configurable URL). Tests construct the
    adapter directly with a fake client instead of going through this factory.
    """
    endpoint = settings.deepseek_endpoint
    if endpoint != OFFICIAL_ENDPOINT:
        raise DeepSeekConfigurationError(
            f"deepseek_endpoint must be the official endpoint {OFFICIAL_ENDPOINT!r}"
        )
    client: DeepSeekApiClient | None = None
    if api_key:
        client = OpenAIDeepSeekApiClient(
            api_key=api_key, base_url=endpoint, timeout=settings.deepseek_request_timeout_seconds
        )
    return DeepSeekTranslationAdapter(
        client=client,
        endpoint=endpoint,
        model=settings.deepseek_model,
        session_dir=settings.workspace / "translation_sessions",
        identifiers=identifiers,
        timeout_seconds=settings.deepseek_request_timeout_seconds,
        max_retries=settings.deepseek_max_retries,
    )
