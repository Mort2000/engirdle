"""DeepSeek translation adapter (unit protocol v2, design §8.2/§8.3).

Implements the TranslationAdapter protocol over the ProcessingPlan unit
projection: sentence batches stay bare JSON arrays; one table is exactly one
structured request whose reply must preserve block identity, shape and cell
IDs. Inline code literals and link URIs are protected client-side by stable
placeholders and restored after validation, so they never appear in any
request, history, journal or retry log.

The full logical session (system + code-free complete-article context +
accepted unit turns) is replayed on every request so terminology stays
consistent, with no sliding window or downgrade. State is reconstructed from
a durable per-checkpoint journal, so a worker can resume a translation
session even across a process restart (lease recovery).
"""

from __future__ import annotations

import logging
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any, TypeVar

from pydantic import ValidationError

from engirdle_pc.modules.content.domain.entities import ArticleRevision
from engirdle_pc.modules.content.domain.plan import (
    ProcessingPlan,
    SentenceBatchUnit,
    TableUnit,
)
from engirdle_pc.modules.translation.application.dto import (
    PROMPT_VERSION,
    REASONING_EFFORT,
    THINKING_MODE,
    build_source_context,
    build_system_prompt,
    build_unit_request,
    parse_table_response,
    parse_translation_list,
    unit_protected_map,
)
from engirdle_pc.modules.translation.application.ports import TranslationUnit
from engirdle_pc.modules.translation.application.units import (
    AcceptedTranslation,
    ProtectedTokenMap,
    SentenceTranslation,
    SentenceUnitTranslation,
    TableTranslatedCell,
    TableUnitTranslation,
    verify_protected_tokens,
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

    def begin(self, revision: ArticleRevision, plan: ProcessingPlan) -> str:
        """Initialize a durable session journal and return its checkpoint id.

        Deliberately makes no network call: the code-free context is sent as
        part of the first 'translate_unit' request.
        """
        checkpoint_id = self._identifiers.new()
        TranslationSessionJournal.create(
            directory=self._session_dir,
            checkpoint_id=checkpoint_id,
            source_sha256=sha256_text(build_source_context(revision, plan)),
            prompt_version=self._prompt_version,
        )
        return checkpoint_id

    def translate_unit(
        self,
        revision: ArticleRevision,
        plan: ProcessingPlan,
        unit: TranslationUnit,
        checkpoint_id: str,
    ) -> AcceptedTranslation:
        journal = self._load_journal(checkpoint_id)
        self._verify_journal_freshness(journal, revision, plan)
        protected_map = unit_protected_map(unit)
        request = build_unit_request(unit)
        messages = self._build_messages(revision, plan, unit, journal, request)
        client = self._require_client()

        def attempt() -> tuple[CompletionResult, AcceptedTranslation]:
            # Validation runs inside the retry loop so a transiently malformed
            # model response (wrong length, fenced, shape-damaged table) gets
            # the same bounded retry budget as transport errors.
            result = client.create_chat_completion(
                model=self.model,
                messages=messages,
                extra_body=self._extra_body(),
                timeout=self._timeout,
            )
            return result, self._validate(result, unit, protected_map)

        result, validated = self._retry_request(attempt)
        # Persist only the validated reply; a protocol failure must not pollute
        # the accepted history that subsequent units (or a retry) will replay.
        journal.accept_unit(unit.unit_id, result.content)
        self._log_usage(unit, result)
        return validated

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
        self,
        journal: TranslationSessionJournal,
        revision: ArticleRevision,
        plan: ProcessingPlan,
    ) -> None:
        """Reject a journal that does not match this revision / prompt version.

        Guards against checkpoint_id reuse across revisions or a stale journal
        left by an older prompt version after an upgrade.
        """
        expected_source_sha256 = sha256_text(build_source_context(revision, plan))
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
        plan: ProcessingPlan,
        unit: TranslationUnit,
        journal: TranslationSessionJournal,
        request: str,
    ) -> list[dict[str, str]]:
        messages: list[dict[str, str]] = [
            {"role": "system", "content": build_system_prompt()},
            {"role": "user", "content": build_source_context(revision, plan)},
        ]
        # Replay accepted history in article order: only plan units are ever
        # requested, so code blocks and dividers can never enter the history.
        for prior in plan.translation.units:
            if prior.unit_id == unit.unit_id:
                break
            reply = journal.accepted.get(prior.unit_id)
            if reply is None:
                raise TranslationProtocolError(
                    f"cannot rebuild history: unit {prior.unit_id} precedes "
                    f"{unit.unit_id} but has no accepted translation"
                )
            messages.append(
                {"role": "user", "content": build_unit_request(prior)}
            )
            messages.append({"role": "assistant", "content": reply})
        else:
            raise TranslationProtocolError(
                f"unit {unit.unit_id} is not part of the translation plan for "
                f"revision {revision.article_id}/{revision.revision}"
            )
        messages.append({"role": "user", "content": request})
        return messages

    def _extra_body(self) -> dict[str, Any]:
        return {
            "thinking": {"type": self._thinking},
            "reasoning_effort": self._reasoning_effort,
        }

    def _retry_request(self, operation: Callable[[], _T]) -> _T:
        """Retry transient transport errors and transiently-malformed responses."""
        attempt = 0
        while True:
            try:
                return operation()
            except TranslationError as error:
                if not _is_retryable(error) or attempt >= self._max_retries:
                    raise
                self._sleeper(min(self._retry_backoff_seconds * (2**attempt), 10.0))
                attempt += 1

    def _validate(
        self,
        result: CompletionResult,
        unit: TranslationUnit,
        protected_map: ProtectedTokenMap,
    ) -> AcceptedTranslation:
        if isinstance(unit, SentenceBatchUnit):
            return self._validate_sentences(result, unit, protected_map)
        if isinstance(unit, TableUnit):
            return self._validate_table(result, unit, protected_map)
        raise TranslationProtocolError(
            f"unknown translation unit type {type(unit).__name__}"
        )

    def _validate_sentences(
        self,
        result: CompletionResult,
        unit: SentenceBatchUnit,
        protected_map: ProtectedTokenMap,
    ) -> AcceptedTranslation:
        try:
            translations = parse_translation_list(result.content)
        except ValidationError as error:
            raise TranslationProtocolError(
                f"model response for unit {unit.block_id} is not a JSON array of "
                f"non-empty strings"
            ) from error
        if len(translations) != len(unit.sentences):
            raise TranslationProtocolError(
                f"model returned {len(translations)} translations for unit "
                f"{unit.block_id} which has {len(unit.sentences)} sentences"
            )
        try:
            verify_protected_tokens(protected_map, tuple(translations))
        except ValueError as error:
            raise TranslationProtocolError(str(error)) from error
        restored = [protected_map.restore(text) for text in translations]
        return AcceptedTranslation(
            translation=SentenceUnitTranslation(
                block_id=unit.block_id,
                translations=tuple(
                    SentenceTranslation(
                        sentence_id=sentence.sentence_id, text_zh=restored[index]
                    )
                    for index, sentence in enumerate(unit.sentences)
                ),
            ),
            request_id=result.request_id,
        )

    def _validate_table(
        self,
        result: CompletionResult,
        unit: TableUnit,
        protected_map: ProtectedTokenMap,
    ) -> AcceptedTranslation:
        try:
            table = parse_table_response(result.content)
        except ValidationError as error:
            raise TranslationProtocolError(
                f"model response for table {unit.block_id} is not the same "
                f"structured JSON object"
            ) from error
        # The reply must be the SAME table, position by position: identity,
        # column count, alignment sequence, header cell ID sequence and the
        # full 2D row cell ID sequence. A set comparison is not enough — a
        # model that swaps IDs between cells would bind translations to the
        # wrong cell.
        expected_header = tuple(cell.cell_id for cell in unit.header)
        actual_header = tuple(cell.cell_id for cell in table.header)
        expected_rows = tuple(
            tuple(cell.cell_id for cell in row) for row in unit.rows
        )
        actual_rows = tuple(tuple(cell.cell_id for cell in row) for row in table.rows)
        if (
            table.block_id != unit.block_id
            or table.columns != len(unit.header)
            or table.alignments != [alignment.value for alignment in unit.alignments]
            or actual_header != expected_header
            or actual_rows != expected_rows
            or len({*actual_header, *(cell for row in actual_rows for cell in row)})
            != len(expected_header) + sum(len(row) for row in expected_rows)
        ):
            raise TranslationProtocolError(
                f"model changed the structure or cell positions of table "
                f"{unit.block_id}"
            )
        cells_in_order = [*table.header, *(cell for row in table.rows for cell in row)]
        try:
            verify_protected_tokens(
                protected_map, tuple(cell.text for cell in cells_in_order)
            )
        except ValueError as error:
            raise TranslationProtocolError(str(error)) from error
        cells = tuple(
            TableTranslatedCell(
                cell_id=cell.cell_id, text_zh=protected_map.restore(cell.text)
            )
            for cell in cells_in_order
        )
        return AcceptedTranslation(
            translation=TableUnitTranslation(block_id=unit.block_id, cells=cells),
            request_id=result.request_id,
        )

    def _log_usage(self, unit: TranslationUnit, result: CompletionResult) -> None:
        # Structured usage only — never log content, translations or reasoning.
        LOGGER.info(
            "deepseek translated unit",
            extra={
                "unit_id": unit.unit_id,
                "unit_kind": "table" if isinstance(unit, TableUnit) else "sentences",
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
