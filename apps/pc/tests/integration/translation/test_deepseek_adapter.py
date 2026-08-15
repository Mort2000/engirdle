"""Contract tests for the DeepSeek translation adapter using a scripted fake client.

These exercise the unit protocol v2 (sentence batches as bare arrays with
protected-token round-trips, whole-table objects with same-shape validation),
the validation rules (length/non-array/non-JSON/empty/dropped placeholder/cell
identity drift), protocol+transient retry without context compression, journal
freshness on the prompt version, and durable cross-instance resume. No network
is touched and no real API call is made: the adapter is driven by a fake client,
and the real ``openai`` exception/client paths are exercised only with
constructed objects (``_map_api_error``) or to assert the endpoint lock.
"""

from __future__ import annotations

import json
from collections import deque
from collections.abc import Callable
from dataclasses import replace
from pathlib import Path

import httpx
import pytest
from openai import APIStatusError, APITimeoutError

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.modules.content.domain.plan import (
    ProcessingPlan,
    SentenceBatchUnit,
    TableUnit,
)
from engirdle_pc.modules.content.public import (
    ArticleRevision,
    RevisionStatus,
    SourceAttribution,
    parse_markdown,
)
from engirdle_pc.modules.translation.application.dto import PROMPT_VERSION
from engirdle_pc.modules.translation.application.units import (
    ProtectedToken,
    ProtectedTokenMap,
    SentenceUnitTranslation,
    TableUnitTranslation,
)
from engirdle_pc.modules.translation.infrastructure.chat_client import (
    OFFICIAL_ENDPOINT,
    CompletionResult,
    OpenAIDeepSeekApiClient,
    _map_api_error,
    classify_api_error,
)
from engirdle_pc.modules.translation.infrastructure.deepseek_adapter import (
    DeepSeekTranslationAdapter,
    build_deepseek_adapter,
)
from engirdle_pc.modules.translation.infrastructure.deepseek_errors import (
    DeepSeekConfigurationError,
    TranslationAuthError,
    TranslationContextLimitError,
    TranslationProtocolError,
    TranslationQuotaError,
    TranslationRateLimitError,
    TranslationServerError,
    TranslationTimeoutError,
)
from engirdle_pc.shared.infrastructure.runtime import UuidIdentifierGenerator

CODE_SENTINEL = "ZQX9-JANUS-SECRET-CODE"


def _placeholder(index: int) -> str:
    """The per-mille protected placeholder for a token index (‰index‰)."""
    token_map = ProtectedTokenMap(tokens=(ProtectedToken(index, "literal"),))
    return token_map.placeholders()[0]


class FakeDeepSeekApiClient:
    def __init__(self) -> None:
        self.calls: list[list[dict[str, str]]] = []
        self.extra_bodies: list[dict[str, object]] = []
        self._responses: deque[object] = deque()
        self.models: list[str] = ["deepseek-v4-flash"]
        self.models_error: Exception | None = None

    def queue(self, item: object) -> None:
        self._responses.append(item)

    def create_chat_completion(
        self,
        *,
        model: str,
        messages: list[dict[str, str]],
        extra_body: dict[str, object],
        timeout: float,
    ) -> CompletionResult:
        self.calls.append([dict(message) for message in messages])
        self.extra_bodies.append(dict(extra_body))
        if not self._responses:
            raise AssertionError("no scripted response queued")
        item = self._responses.popleft()
        if isinstance(item, Exception):
            raise item
        assert isinstance(item, CompletionResult)
        return item

    def list_models(self, *, timeout: float) -> list[str]:
        if self.models_error is not None:
            raise self.models_error
        return self.models


def _completion(content: str, request_id: str = "req-1") -> CompletionResult:
    return CompletionResult(
        content=content, finish_reason="stop", request_id=request_id, usage=None
    )


def _revision(body: str, *, title: str = "Reading Practice") -> ArticleRevision:
    parsed = parse_markdown(body)
    return ArticleRevision(
        article_id="art-1",
        revision=1,
        title=title,
        raw_text=body,
        normalized_text=parsed.canonical_markdown,
        source=SourceAttribution(
            author=None, display_name=None, url=None, license_name="unknown"
        ),
        source_sha256="src",
        normalized_sha256="norm",
        structure_sha256="struct",
        status=RevisionStatus.APPROVED,
        blocks=parsed.blocks,
    )


def _adapter(
    tmp_path: Path,
    client: object | None,
    *,
    max_retries: int = 3,
    sleeper: Callable[[float], None] = lambda _: None,
    prompt_version: str = PROMPT_VERSION,
) -> DeepSeekTranslationAdapter:
    return DeepSeekTranslationAdapter(
        client=client,  # type: ignore[arg-type]
        endpoint=OFFICIAL_ENDPOINT,
        model="deepseek-v4-flash",
        session_dir=tmp_path / "translation_sessions",
        identifiers=UuidIdentifierGenerator(),
        max_retries=max_retries,
        retry_backoff_seconds=0.0,
        sleeper=sleeper,
        prompt_version=prompt_version,
    )


def _sentence_unit(plan: ProcessingPlan, index: int = 0) -> SentenceBatchUnit:
    return plan.translation.sentence_units[index]


def _table_unit(plan: ProcessingPlan) -> TableUnit:
    return plan.translation.table_units[0]


def _request_payload(client: FakeDeepSeekApiClient, call: int) -> object:
    return json.loads(client.calls[call][-1]["content"])


def _table_reply(unit: TableUnit, translations: list[str]) -> str:
    """Serialize a valid same-shape table reply from a flat cell text list."""
    translated = iter(translations)
    return json.dumps(
        {
            "block_id": unit.block_id,
            "columns": len(unit.header),
            "alignments": [alignment.value for alignment in unit.alignments],
            "header": [
                {"cell_id": cell.cell_id, "text": next(translated)}
                for cell in unit.header
            ],
            "rows": [
                [
                    {"cell_id": cell.cell_id, "text": next(translated)}
                    for cell in row
                ]
                for row in unit.rows
            ],
        },
        ensure_ascii=False,
    )


# -- begin / journal freshness ---------------------------------------------


def test_begin_does_not_call_the_client_and_creates_a_journal(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    revision = _revision("One.")
    plan = ProcessingPlan.derive(revision)

    checkpoint = adapter.begin(revision, plan)

    assert client.calls == []
    assert checkpoint
    journal_files = list((tmp_path / "translation_sessions").glob("*.json"))
    assert len(journal_files) == 1


def test_journal_with_a_stale_prompt_version_is_rejected(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=0)
    revision = _revision("One.")
    plan = ProcessingPlan.derive(revision)
    checkpoint = adapter.begin(revision, plan)

    older = _adapter(
        tmp_path, client, max_retries=0, prompt_version="full-article-sequential-blocks@v1"
    )
    with pytest.raises(TranslationProtocolError):
        older.translate_unit(revision, plan, _sentence_unit(plan), checkpoint)


# -- sentence batches ------------------------------------------------------


def test_sentence_batch_is_a_bare_array_with_positional_id_mapping(
    tmp_path: Path,
) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    revision = _revision("Hello world. Good morning.")
    plan = ProcessingPlan.derive(revision)
    unit = _sentence_unit(plan)
    client.queue(_completion('["你好，世界。", "早上好。"]', request_id="req-xyz"))  # noqa: RUF001

    checkpoint = adapter.begin(revision, plan)
    accepted = adapter.translate_unit(revision, plan, unit, checkpoint)

    assert isinstance(accepted.translation, SentenceUnitTranslation)
    batch = accepted.translation
    assert batch.block_id == unit.block_id
    assert [t.sentence_id for t in batch.translations] == [
        sentence.sentence_id for sentence in unit.sentences
    ]
    assert [t.text_zh for t in batch.translations] == ["你好，世界。", "早上好。"]  # noqa: RUF001
    assert accepted.request_id == "req-xyz"

    messages = client.calls[0]
    assert messages[0]["role"] == "system"
    assert messages[1]["role"] == "user"  # complete-article context
    assert messages[2]["role"] == "user"
    # The sentence request is a bare JSON array - no keys, no wrapper object.
    assert json.loads(messages[2]["content"]) == ["Hello world.", "Good morning."]
    assert client.extra_bodies[0] == {
        "thinking": {"type": "enabled"},
        "reasoning_effort": "max",
    }


def test_inline_code_placeholder_round_trip_and_literal_never_sent(
    tmp_path: Path,
) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    revision = _revision("Run `pip install engirdle` now.")
    plan = ProcessingPlan.derive(revision)
    unit = _sentence_unit(plan)
    literal = "pip install engirdle"
    placeholder = _placeholder(0)
    client.queue(_completion(f'["现在运行 {placeholder} 吧。"]'))

    checkpoint = adapter.begin(revision, plan)
    accepted = adapter.translate_unit(revision, plan, unit, checkpoint)

    request_text = client.calls[0][-1]["content"]
    assert literal not in request_text  # the literal never enters the request
    assert placeholder in request_text  # a stable placeholder replaces it
    text_zh = accepted.translation.translations[0].text_zh  # type: ignore[attr-defined]
    assert literal in text_zh  # restored verbatim after the model returns
    assert placeholder not in text_zh


def test_dropped_placeholder_is_a_protocol_error(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=0)
    revision = _revision("Run `pip install engirdle` now.")
    plan = ProcessingPlan.derive(revision)
    unit = _sentence_unit(plan)
    checkpoint = adapter.begin(revision, plan)

    client.queue(_completion('["现在运行安装命令吧。"]'))  # placeholder dropped
    with pytest.raises(TranslationProtocolError):
        adapter.translate_unit(revision, plan, unit, checkpoint)


def test_length_mismatch_is_rejected_without_polluting_history(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=0)
    revision = _revision("One. Two.")
    plan = ProcessingPlan.derive(revision)
    unit = _sentence_unit(plan)
    checkpoint = adapter.begin(revision, plan)

    client.queue(_completion('["only one translation"]'))  # wrong length
    with pytest.raises(TranslationProtocolError):
        adapter.translate_unit(revision, plan, unit, checkpoint)

    # The failed response must not enter history: a fresh successful call
    # rebuilds byte-identical messages (no assistant turn appended).
    client.queue(_completion('["一。", "二。"]'))
    adapter.translate_unit(revision, plan, unit, checkpoint)
    assert client.calls[0] == client.calls[1]
    assert [m["role"] for m in client.calls[0]] == ["system", "user", "user"]


def test_protocol_error_is_retried_within_budget_then_succeeds(tmp_path: Path) -> None:
    sleeps: list[float] = []
    client = FakeDeepSeekApiClient()
    adapter = _adapter(
        tmp_path, client, max_retries=2, sleeper=lambda delay: sleeps.append(delay)
    )
    revision = _revision("One.")
    plan = ProcessingPlan.derive(revision)
    unit = _sentence_unit(plan)
    checkpoint = adapter.begin(revision, plan)

    client.queue(_completion('["extra", "items"]'))  # wrong length -> protocol error
    client.queue(_completion('["一。"]'))  # valid on retry
    accepted = adapter.translate_unit(revision, plan, unit, checkpoint)

    batch = accepted.translation
    assert isinstance(batch, SentenceUnitTranslation)
    assert [t.text_zh for t in batch.translations] == ["一。"]
    assert len(sleeps) == 1  # one retry after the malformed first response
    assert len(client.calls) == 2


def test_non_array_and_empty_member_responses_are_rejected(tmp_path: Path) -> None:
    revision = _revision("One. Two.")
    plan = ProcessingPlan.derive(revision)
    unit = _sentence_unit(plan)

    for bad_content in ('{"translations": ["一。", "二。"]}', "not json", '["一。", ""]'):
        client = FakeDeepSeekApiClient()
        adapter = _adapter(tmp_path, client, max_retries=0)
        checkpoint = adapter.begin(revision, plan)
        client.queue(_completion(bad_content))
        with pytest.raises(TranslationProtocolError):
            adapter.translate_unit(revision, plan, unit, checkpoint)


def test_transient_errors_retry_without_compressing_context(tmp_path: Path) -> None:
    sleeps: list[float] = []
    client = FakeDeepSeekApiClient()
    adapter = _adapter(
        tmp_path, client, max_retries=2, sleeper=lambda delay: sleeps.append(delay)
    )
    revision = _revision("One.")
    plan = ProcessingPlan.derive(revision)
    unit = _sentence_unit(plan)
    checkpoint = adapter.begin(revision, plan)

    client.queue(TranslationRateLimitError("throttled"))
    client.queue(TranslationServerError("boom"))
    client.queue(_completion('["一。"]'))

    accepted = adapter.translate_unit(revision, plan, unit, checkpoint)

    batch = accepted.translation
    assert isinstance(batch, SentenceUnitTranslation)
    assert [t.text_zh for t in batch.translations] == ["一。"]
    assert len(sleeps) == 2
    assert len(client.calls) == 3
    # Every retry replays the identical, uncompressed message list.
    assert client.calls[0] == client.calls[1] == client.calls[2]


def test_exhausted_transient_retries_raise(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=1)
    revision = _revision("One.")
    plan = ProcessingPlan.derive(revision)
    unit = _sentence_unit(plan)
    checkpoint = adapter.begin(revision, plan)

    client.queue(TranslationRateLimitError("throttled"))
    client.queue(TranslationRateLimitError("throttled"))

    with pytest.raises(TranslationRateLimitError):
        adapter.translate_unit(revision, plan, unit, checkpoint)
    assert len(client.calls) == 2  # initial + 1 retry


def test_non_transient_error_is_not_retried(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=3)
    revision = _revision("One.")
    plan = ProcessingPlan.derive(revision)
    unit = _sentence_unit(plan)
    checkpoint = adapter.begin(revision, plan)
    client.queue(TranslationAuthError("bad key"))

    with pytest.raises(TranslationAuthError):
        adapter.translate_unit(revision, plan, unit, checkpoint)
    assert len(client.calls) == 1


# -- table units -----------------------------------------------------------


def test_table_request_uses_the_wire_object_and_round_trips(
    tmp_path: Path,
) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    revision = _revision(
        "| Name | Value |\n| --- | ---: |\n| Alpha | 1 |\n| Beta | 2 |"
    )
    plan = ProcessingPlan.derive(revision)
    unit = _table_unit(plan)
    client.queue(
        _completion(
            _table_reply(unit, ["名称", "数值", "甲", "一", "乙", "二"]),
            request_id="req-t1",
        )
    )

    checkpoint = adapter.begin(revision, plan)
    accepted = adapter.translate_unit(revision, plan, unit, checkpoint)

    wire = _request_payload(client, 0)
    assert isinstance(wire, dict)
    assert wire["block_id"] == unit.block_id
    assert wire["columns"] == 2
    assert wire["alignments"] == ["default", "right"]
    assert [cell["cell_id"] for cell in wire["header"]] == [
        cell.cell_id for cell in unit.header
    ]
    assert [cell["text"] for cell in wire["header"]] == ["Name", "Value"]

    assert isinstance(accepted.translation, TableUnitTranslation)
    table = accepted.translation
    assert table.block_id == unit.block_id
    assert accepted.request_id == "req-t1"
    assert [cell.text_zh for cell in table.cells] == ["名称", "数值", "甲", "一", "乙", "二"]
    assert table.for_cell(unit.rows[1][1].cell_id).text_zh == "二"


def test_table_cell_identity_mismatch_is_retried_then_can_succeed(
    tmp_path: Path,
) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=1)
    revision = _revision("| A | B |\n| --- | --- |\n| 1 | 2 |")
    plan = ProcessingPlan.derive(revision)
    unit = _table_unit(plan)
    checkpoint = adapter.begin(revision, plan)

    # The model renamed one cell id: a protocol error inside the retry budget.
    drifted = json.loads(_table_reply(unit, ["甲", "乙", "一", "二"]))
    drifted["header"][0]["cell_id"] = "cell-model-invented"
    client.queue(_completion(json.dumps(drifted, ensure_ascii=False)))
    client.queue(_completion(_table_reply(unit, ["甲", "乙", "一", "二"])))

    accepted = adapter.translate_unit(revision, plan, unit, checkpoint)

    assert len(client.calls) == 2  # drift + corrected retry
    table = accepted.translation
    assert isinstance(table, TableUnitTranslation)
    assert [cell.text_zh for cell in table.cells] == ["甲", "乙", "一", "二"]


def test_table_with_an_empty_cell_text_is_rejected(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=0)
    revision = _revision("| A | B |\n| --- | --- |\n| 1 | 2 |")
    plan = ProcessingPlan.derive(revision)
    unit = _table_unit(plan)
    checkpoint = adapter.begin(revision, plan)

    empty_cell = json.loads(_table_reply(unit, ["甲", "乙", "一", "二"]))
    empty_cell["header"][1]["text"] = "   "
    client.queue(_completion(json.dumps(empty_cell, ensure_ascii=False)))
    with pytest.raises(TranslationProtocolError):
        adapter.translate_unit(revision, plan, unit, checkpoint)


def test_table_protected_token_dropped_is_a_protocol_error(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=0)
    revision = _revision("| Key | Value |\n| --- | --- |\n| `token-x` | 1 |")
    plan = ProcessingPlan.derive(revision)
    unit = _table_unit(plan)
    checkpoint = adapter.begin(revision, plan)

    reply = json.loads(_table_reply(unit, ["键", "值", "令牌", "一"]))
    client.queue(_completion(json.dumps(reply, ensure_ascii=False)))

    with pytest.raises(TranslationProtocolError):
        adapter.translate_unit(revision, plan, unit, checkpoint)

    # The request really did carry a protected placeholder, never the literal.
    request_text = client.calls[0][-1]["content"]
    assert "token-x" not in request_text
    assert _placeholder(0) in request_text


def test_link_with_display_text_translates_without_a_token(tmp_path: Path) -> None:
    """A plain link's URI never enters the wire, so nothing needs protecting.

    Regression: link URIs used to be registered as tokens even though the
    wire only carries the display text, so every real reply failed the
    protected-token check.
    """
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    revision = _revision("See [the official docs](https://example.com/docs) now.")
    plan = ProcessingPlan.derive(revision)
    unit = _sentence_unit(plan)
    checkpoint = adapter.begin(revision, plan)
    client.queue(_completion('["现在查看官方文档吧。"]'))

    accepted = adapter.translate_unit(revision, plan, unit, checkpoint)

    request_text = client.calls[0][-1]["content"]
    assert "https://example.com/docs" not in request_text  # URI never sent
    assert "the official docs" in request_text  # display text translates
    text_zh = accepted.translation.translations[0].text_zh  # type: ignore[attr-defined]
    assert text_zh == "现在查看官方文档吧。"


def test_autolink_display_text_is_protected_verbatim(tmp_path: Path) -> None:
    """A link whose visible text IS the URL must survive translation."""
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    revision = _revision("Visit <https://example.com/a> today.")
    plan = ProcessingPlan.derive(revision)
    unit = _sentence_unit(plan)
    checkpoint = adapter.begin(revision, plan)

    request_text_placeholder = _placeholder(0)
    client.queue(_completion(f'["访问 {request_text_placeholder} 今天。"]'))
    accepted = adapter.translate_unit(revision, plan, unit, checkpoint)

    request_text = client.calls[0][-1]["content"]
    assert "https://example.com/a" not in request_text
    assert request_text_placeholder in request_text
    text_zh = accepted.translation.translations[0].text_zh  # type: ignore[attr-defined]
    assert "https://example.com/a" in text_zh  # URL restored untouched


def test_repeated_inline_code_literal_gets_distinct_placeholders(
    tmp_path: Path,
) -> None:
    """Two occurrences of one literal each carry their own placeholder.

    Regression: the map used to deduplicate literals and count a single
    global replacement, so any repeated literal failed verification.
    """
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    revision = _revision("Use `foo` here. Then use `foo` there.")
    plan = ProcessingPlan.derive(revision)
    unit = _sentence_unit(plan)
    checkpoint = adapter.begin(revision, plan)

    first, second = _placeholder(0), _placeholder(1)
    assert first != second
    client.queue(_completion(f'["这里用 {first}。", "那里也用 {second}。"]'))
    accepted = adapter.translate_unit(revision, plan, unit, checkpoint)

    request_text = client.calls[0][-1]["content"]
    assert request_text.count(first) == 1
    assert request_text.count(second) == 1
    texts = [
        entry.text_zh
        for entry in accepted.translation.translations  # type: ignore[attr-defined]
    ]
    assert all("foo" in text for text in texts)


def test_placeholder_swapped_between_sentences_is_rejected(tmp_path: Path) -> None:
    """Swapping two placeholders across sentences must fail slot checks.

    Regression: verification used to count global occurrences, so a swap —
    which still shows each placeholder exactly once — silently bound the
    wrong literal to the wrong sentence.
    """
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=0)
    revision = _revision("Run `alpha` then run `beta` now.")
    plan = ProcessingPlan.derive(revision)
    unit = _sentence_unit(plan)
    checkpoint = adapter.begin(revision, plan)

    first, second = _placeholder(0), _placeholder(1)
    # Model swapped the placeholders between the two sentences.
    client.queue(_completion(f'["先跑 {second}。", "再跑 {first}。"]'))
    with pytest.raises(TranslationProtocolError):
        adapter.translate_unit(revision, plan, unit, checkpoint)


def test_table_placeholder_swapped_between_cells_is_rejected(tmp_path: Path) -> None:
    """The same slot rule applies cell-to-cell inside a table."""
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=0)
    revision = _revision("| `a` | `b` |\n| --- | --- |\n| 1 | 2 |")
    plan = ProcessingPlan.derive(revision)
    unit = _table_unit(plan)
    checkpoint = adapter.begin(revision, plan)

    first, second = _placeholder(0), _placeholder(1)
    reply = json.loads(_table_reply(unit, [first, second, "一", "二"]))
    # Swap header cell texts: right placeholders, wrong cells.
    reply["header"][0]["text"], reply["header"][1]["text"] = (
        reply["header"][1]["text"],
        reply["header"][0]["text"],
    )
    client.queue(_completion(json.dumps(reply, ensure_ascii=False)))
    with pytest.raises(TranslationProtocolError):
        adapter.translate_unit(revision, plan, unit, checkpoint)


def test_literal_containing_a_placeholder_pattern_restores_once(tmp_path: Path) -> None:
    """A code literal that itself looks like a placeholder must not cascade.

    Regression: restore used sequential str.replace, so restoring token 0
    exposed the pattern inside its literal to token 1's replacement.
    """
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    tricky = "x\u20301\u2030y"
    revision = _revision(f"Use `{tricky}` and `other` now.")
    plan = ProcessingPlan.derive(revision)
    unit = _sentence_unit(plan)
    checkpoint = adapter.begin(revision, plan)
    client.queue(
        _completion(f'["用 {_placeholder(0)} 和 {_placeholder(1)}。"]')
    )

    accepted = adapter.translate_unit(revision, plan, unit, checkpoint)

    text_zh = accepted.translation.translations[0].text_zh  # type: ignore[attr-defined]
    assert tricky in text_zh  # restored verbatim, not re-substituted
    assert "other" in text_zh
    # The sequential-replace cascade would have turned x‰1‰y into x other y.
    assert "x other y" not in text_zh


def test_placeholder_lookalikes_are_rejected(tmp_path: Path) -> None:
    """Non-canonical placeholder spellings must fail verification.

    A count-and-int() pipeline normalizes lookalikes onto real tokens:
    leading zeros and non-ASCII digit spellings would restore the wrong
    literal, and an invented index would leak the marker into the published
    artifact. Verification compares full canonical spellings and
    rejects any stray sentinel.
    """
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=0)
    revision = _revision("Run `pip install engirdle` now.")
    plan = ProcessingPlan.derive(revision)
    unit = _sentence_unit(plan)
    checkpoint = adapter.begin(revision, plan)
    canonical = _placeholder(0)

    sentinel = "\u2030"
    for bad in (
        f"{sentinel}00{sentinel}",  # leading zero
        f"{sentinel}\u0660{sentinel}",  # Arabic-Indic digit zero
        f"{sentinel}999{sentinel}",  # invented index
    ):
        client.queue(_completion(json.dumps([f"现在运行 {bad} 吧。"], ensure_ascii=False)))
        with pytest.raises(TranslationProtocolError):
            adapter.translate_unit(revision, plan, unit, checkpoint)

    # The canonical spelling still round-trips after all that.
    client.queue(_completion(f'["现在运行 {canonical} 吧。"]'))
    accepted = adapter.translate_unit(revision, plan, unit, checkpoint)
    text_zh = accepted.translation.translations[0].text_zh  # type: ignore[attr-defined]
    assert "pip install engirdle" in text_zh


def test_table_header_row_cell_swap_is_rejected(tmp_path: Path) -> None:
    """Swapping cell IDs between header and row must fail position checks.

    Regression: the identity comparison used sets, so a model that moved IDs
    to the wrong positions still passed and bound text to the wrong cells.
    """
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=0)
    revision = _revision("| A | B |\n| --- | --- |\n| 1 | 2 |")
    plan = ProcessingPlan.derive(revision)
    unit = _table_unit(plan)
    checkpoint = adapter.begin(revision, plan)

    swapped = json.loads(_table_reply(unit, ["甲", "乙", "一", "二"]))
    swapped["header"][0]["cell_id"], swapped["rows"][0][0]["cell_id"] = (
        swapped["rows"][0][0]["cell_id"],
        swapped["header"][0]["cell_id"],
    )
    client.queue(_completion(json.dumps(swapped, ensure_ascii=False)))
    with pytest.raises(TranslationProtocolError):
        adapter.translate_unit(revision, plan, unit, checkpoint)


def test_table_row_order_and_alignment_drift_are_rejected(tmp_path: Path) -> None:
    """Reordered rows and changed alignments both reject."""
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=0)
    revision = _revision("| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |")
    plan = ProcessingPlan.derive(revision)
    unit = _table_unit(plan)
    checkpoint = adapter.begin(revision, plan)

    reordered = json.loads(_table_reply(unit, ["甲", "乙", "一", "二", "三", "四"]))
    reordered["rows"].reverse()
    client.queue(_completion(json.dumps(reordered, ensure_ascii=False)))
    with pytest.raises(TranslationProtocolError):
        adapter.translate_unit(revision, plan, unit, checkpoint)

    realigned = json.loads(_table_reply(unit, ["甲", "乙", "一", "二", "三", "四"]))
    realigned["alignments"] = ["default", "center"]
    client.queue(_completion(json.dumps(realigned, ensure_ascii=False)))
    with pytest.raises(TranslationProtocolError):
        adapter.translate_unit(revision, plan, unit, checkpoint)


# -- history rebuild -------------------------------------------------------


def test_subsequent_unit_replays_the_full_accepted_history(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    revision = _revision("First. Second.\n\nThird.")
    plan = ProcessingPlan.derive(revision)
    checkpoint = adapter.begin(revision, plan)
    units = plan.translation.units

    client.queue(_completion('["第一句。", "第二句。"]'))
    adapter.translate_unit(revision, plan, units[0], checkpoint)
    client.queue(_completion('["第三句。"]'))
    adapter.translate_unit(revision, plan, units[1], checkpoint)

    second_messages = client.calls[1]
    assert [m["role"] for m in second_messages] == [
        "system",
        "user",
        "user",
        "assistant",
        "user",
    ]
    assert json.loads(second_messages[3]["content"]) == ["第一句。", "第二句。"]
    assert json.loads(second_messages[4]["content"]) == ["Third."]


def test_rebuilt_history_never_contains_the_code_sentinel(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    fence = "```"
    revision = _revision(
        f"Opening line.\n\n{fence}python\nSECRET = {CODE_SENTINEL}\n{fence}\n\n"
        f"Closing line.\n\n| H |\n| --- |\n| cell |"
    )
    plan = ProcessingPlan.derive(revision)
    checkpoint = adapter.begin(revision, plan)
    kinds = [type(unit).__name__ for unit in plan.translation.units]
    assert kinds == ["SentenceBatchUnit", "SentenceBatchUnit", "TableUnit"]

    for unit in plan.translation.units:
        if isinstance(unit, TableUnit):
            reply = _table_reply(unit, ["格", "值"])
        else:
            assert isinstance(unit, SentenceBatchUnit)
            reply = json.dumps(["开篇。"] if unit is plan.translation.units[0] else ["收尾。"])
        client.queue(_completion(reply))
        adapter.translate_unit(revision, plan, unit, checkpoint)

    # Later requests replay earlier accepted turns plus the code-free context;
    # the code sentinel must be absent from every request, rebuilt or not.
    for messages in client.calls:
        assert CODE_SENTINEL not in json.dumps(messages, ensure_ascii=False)
    context = client.calls[0][1]["content"]
    assert "omitted_code_block" in context
    assert CODE_SENTINEL not in context


def test_cross_instance_resume_rebuilds_history_from_journal(tmp_path: Path) -> None:
    revision = _revision("First.\n\nSecond.")
    plan = ProcessingPlan.derive(revision)
    units = plan.translation.units

    client_a = FakeDeepSeekApiClient()
    adapter_a = _adapter(tmp_path, client_a)
    checkpoint = adapter_a.begin(revision, plan)
    client_a.queue(_completion('["第一句。"]'))
    adapter_a.translate_unit(revision, plan, units[0], checkpoint)

    # A brand-new adapter instance (e.g. a restarted worker) loads the durable
    # journal and must replay unit 0's accepted translation as context.
    client_b = FakeDeepSeekApiClient()
    adapter_b = _adapter(tmp_path, client_b)
    client_b.queue(_completion('["第二句。"]'))
    adapter_b.translate_unit(revision, plan, units[1], checkpoint)

    messages = client_b.calls[0]
    assert [m["role"] for m in messages] == ["system", "user", "user", "assistant", "user"]
    assert json.loads(messages[3]["content"]) == ["第一句。"]


def test_unit_not_in_plan_is_rejected(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=0)
    revision = _revision("One.\n\nTwo more.")
    plan = ProcessingPlan.derive(revision)
    checkpoint = adapter.begin(revision, plan)
    client.queue(_completion('["一。"]'))
    adapter.translate_unit(revision, plan, plan.translation.units[0], checkpoint)

    rogue = SentenceBatchUnit(
        block_id="rogue-1", sentences=(_sentence_unit(plan).sentences[0],)
    )
    with pytest.raises(TranslationProtocolError):
        adapter.translate_unit(revision, plan, rogue, checkpoint)


def test_stale_journal_is_rejected_on_resume(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=0)
    revision = _revision("One.")
    plan = ProcessingPlan.derive(revision)
    checkpoint = adapter.begin(revision, plan)

    # Reuse the checkpoint against a different revision (different title => a
    # different code-free source hash), as could happen if an id were reused.
    other_revision = replace(revision, title="A Different Article")
    with pytest.raises(TranslationProtocolError):
        adapter.translate_unit(
            other_revision,
            ProcessingPlan.derive(other_revision),
            _sentence_unit(plan),
            checkpoint,
        )


# -- configuration / access ------------------------------------------------


def test_missing_client_raises_configuration_error(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path, client=None)
    revision = _revision("One.")
    plan = ProcessingPlan.derive(revision)
    checkpoint = adapter.begin(revision, plan)  # begin needs no client

    with pytest.raises(DeepSeekConfigurationError):
        adapter.translate_unit(revision, plan, _sentence_unit(plan), checkpoint)
    with pytest.raises(DeepSeekConfigurationError):
        adapter.verify_access()


def test_missing_journal_raises_protocol_error(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    revision = _revision("One.")

    with pytest.raises(TranslationProtocolError):
        adapter.translate_unit(
            revision,
            ProcessingPlan.derive(revision),
            _sentence_unit(ProcessingPlan.derive(revision)),
            "never-begun",
        )


def test_verify_access_propagates_auth_failure(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    client.models_error = TranslationAuthError("bad key")
    adapter = _adapter(tmp_path, client)

    with pytest.raises(TranslationAuthError):
        adapter.verify_access()


def test_verify_access_succeeds_when_models_list_returns(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    adapter.verify_access()  # must not raise


def test_verify_access_rejects_a_model_the_provider_does_not_serve(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    client.models = ["deepseek-v4-pro"]  # configured model "deepseek-v4-flash" absent
    adapter = _adapter(tmp_path, client)
    with pytest.raises(DeepSeekConfigurationError):
        adapter.verify_access()


def test_factory_rejects_unofficial_endpoint(tmp_path: Path) -> None:
    settings = Settings(workspace=tmp_path, deepseek_endpoint="https://evil.example")
    with pytest.raises(DeepSeekConfigurationError):
        build_deepseek_adapter(settings, api_key="some-key", identifiers=UuidIdentifierGenerator())


def test_factory_builds_adapter_without_client_when_key_absent(tmp_path: Path) -> None:
    settings = Settings(workspace=tmp_path)
    adapter = build_deepseek_adapter(settings, api_key=None, identifiers=UuidIdentifierGenerator())
    assert adapter.endpoint == OFFICIAL_ENDPOINT
    assert adapter.model == "deepseek-v4-flash"
    # No key => no client built => translate/verify fail fast with a typed error.
    with pytest.raises(DeepSeekConfigurationError):
        adapter.verify_access()


def test_real_client_refuses_unofficial_endpoint() -> None:
    with pytest.raises(DeepSeekConfigurationError):
        OpenAIDeepSeekApiClient(api_key="irrelevant", base_url="https://evil.example", timeout=1.0)


@pytest.mark.parametrize(
    ("kwargs", "expected"),
    [
        ({"status_code": 401, "message": "nope"}, TranslationAuthError),
        ({"status_code": 403, "message": "nope"}, TranslationAuthError),
        ({"status_code": 402, "message": "nope"}, TranslationQuotaError),
        ({"status_code": 429, "message": "nope"}, TranslationRateLimitError),
        ({"status_code": 500, "message": "nope"}, TranslationServerError),
        ({"status_code": 503, "message": "nope"}, TranslationServerError),
        ({"timeout": True, "message": "x"}, TranslationTimeoutError),
        ({"connection": True, "message": "x"}, TranslationServerError),
        (
            {"status_code": 400, "message": "maximum context length exceeded"},
            TranslationContextLimitError,
        ),
    ],
)
def test_classify_api_error_maps_status_codes(kwargs: dict, expected: type) -> None:
    assert isinstance(classify_api_error(**kwargs), expected)


def _api_status_error(status_code: int, message: str) -> APIStatusError:
    request = httpx.Request("POST", "https://api.deepseek.com/chat/completions")
    return APIStatusError(
        message,
        response=httpx.Response(status_code=status_code, request=request),
        body=None,
    )


def test_map_api_error_translates_real_openai_exceptions() -> None:
    assert isinstance(_map_api_error(_api_status_error(401, "nope")), TranslationAuthError)
    assert isinstance(_map_api_error(_api_status_error(402, "nope")), TranslationQuotaError)
    assert isinstance(_map_api_error(_api_status_error(429, "nope")), TranslationRateLimitError)
    assert isinstance(_map_api_error(_api_status_error(500, "nope")), TranslationServerError)
    request = httpx.Request("POST", "https://api.deepseek.com/chat/completions")
    assert isinstance(_map_api_error(APITimeoutError(request=request)), TranslationTimeoutError)


def test_fenced_and_bom_sentence_responses_are_parsed(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    revision = _revision("One. Two.")
    plan = ProcessingPlan.derive(revision)
    unit = _sentence_unit(plan)
    checkpoint = adapter.begin(revision, plan)
    tick = "`"

    fenced = f"{tick * 3}json\n[\"第一句。\", \"第二句。\"]\n{tick * 3}"
    bom = "\ufeff[\"甲。\", \"乙。\"]"
    client.queue(_completion(fenced))
    accepted = adapter.translate_unit(revision, plan, unit, checkpoint)
    batch = accepted.translation
    assert isinstance(batch, SentenceUnitTranslation)
    assert [t.text_zh for t in batch.translations] == ["第一句。", "第二句。"]

    client.queue(_completion(bom))
    accepted = adapter.translate_unit(revision, plan, unit, checkpoint)
    batch = accepted.translation
    assert isinstance(batch, SentenceUnitTranslation)
    assert [t.text_zh for t in batch.translations] == ["甲。", "乙。"]
