"""Contract tests for the DeepSeek translation adapter using a scripted fake client.

These exercise the protocol (no round-zero call, full-history replay, positional
sentence-id mapping), the validation rules (length/non-array/non-JSON/empty),
protocol+transient retry without context compression, and durable cross-instance
resume. No network is touched and no real API call is made: the adapter is driven
by a fake client, and the real ``openai`` exception/client paths are exercised
only with constructed objects (``_map_api_error``) or to assert the endpoint lock.
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
from engirdle_pc.modules.content.public import (
    ArticleRevision,
    Block,
    BlockKind,
    RevisionStatus,
    Sentence,
    SourceAttribution,
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
from engirdle_pc.modules.translation.public import TranslationBatch
from engirdle_pc.shared.infrastructure.runtime import UuidIdentifierGenerator


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


def _sentence(block_id: str, index: int, text: str) -> Sentence:
    return Sentence(sentence_id=f"{block_id}-s{index}", order=index, text=text)


def _block(block_id: str, order: int, texts: list[str]) -> Block:
    return Block(
        block_id=block_id,
        kind=BlockKind.PARAGRAPH,
        order=order,
        sentences=tuple(_sentence(block_id, i, text) for i, text in enumerate(texts)),
    )


def _revision(blocks: list[Block]) -> ArticleRevision:
    return ArticleRevision(
        article_id="art-1",
        revision=1,
        title="Reading Practice",
        raw_text="",
        normalized_text="",
        source=SourceAttribution(
            author=None, display_name=None, url=None, license_name="unknown"
        ),
        source_sha256="src",
        normalized_sha256="norm",
        structure_sha256="struct",
        status=RevisionStatus.APPROVED,
        blocks=tuple(blocks),
    )


def _adapter(
    tmp_path: Path,
    client: object | None,
    *,
    max_retries: int = 3,
    sleeper: Callable[[float], None] = lambda _: None,
) -> DeepSeekTranslationAdapter:
    return DeepSeekTranslationAdapter(
        client=client,  # type: ignore[arg-type]
        endpoint=OFFICIAL_ENDPOINT,
        model="deepseek-v4-flash",
        thinking="enabled",
        reasoning_effort="max",
        session_dir=tmp_path / "translation_sessions",
        identifiers=UuidIdentifierGenerator(),
        max_retries=max_retries,
        retry_backoff_seconds=0.0,
        sleeper=sleeper,
    )


def test_begin_does_not_call_the_client_and_creates_a_journal(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)

    checkpoint = adapter.begin(_revision([_block("b0", 0, ["One."])]))

    assert client.calls == []
    assert checkpoint
    journal_files = list((tmp_path / "translation_sessions").glob("*.json"))
    assert len(journal_files) == 1


def test_translate_block_maps_positional_translations_to_sentence_ids(
    tmp_path: Path,
) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    block = _block("b0", 0, ["Hello world.", "Good morning."])
    revision = _revision([block])
    client.queue(_completion('["你好，世界。", "早上好。"]', request_id="req-xyz"))  # noqa: RUF001

    checkpoint = adapter.begin(revision)
    batch = adapter.translate_block(revision, block, checkpoint)

    assert isinstance(batch, TranslationBatch)
    assert batch.block_id == "b0"
    assert [t.sentence_id for t in batch.translations] == ["b0-s0", "b0-s1"]
    assert [t.text_zh for t in batch.translations] == ["你好，世界。", "早上好。"]  # noqa: RUF001
    assert batch.request_id == "req-xyz"

    messages = client.calls[0]
    assert messages[0]["role"] == "system"
    assert messages[1]["role"] == "user"  # complete-article context
    assert messages[2]["role"] == "user"
    assert json.loads(messages[2]["content"]) == ["Hello world.", "Good morning."]
    assert client.extra_bodies[0] == {
        "thinking": {"type": "enabled"},
        "reasoning_effort": "max",
    }


def test_subsequent_block_replays_the_full_accepted_history(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    block0 = _block("b0", 0, ["First.", "Second."])
    block1 = _block("b1", 1, ["Third."])
    revision = _revision([block0, block1])
    checkpoint = adapter.begin(revision)

    client.queue(_completion('["第一句。", "第二句。"]'))
    adapter.translate_block(revision, block0, checkpoint)
    client.queue(_completion('["第三句。"]'))
    adapter.translate_block(revision, block1, checkpoint)

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


def test_length_mismatch_is_rejected_without_polluting_history(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=0)
    block = _block("b0", 0, ["One.", "Two."])
    revision = _revision([block])
    checkpoint = adapter.begin(revision)

    client.queue(_completion('["only one translation"]'))  # wrong length
    with pytest.raises(TranslationProtocolError):
        adapter.translate_block(revision, block, checkpoint)

    # The failed response must not enter history: a fresh successful call
    # rebuilds byte-identical messages (no assistant turn appended).
    client.queue(_completion('["一。", "二。"]'))
    adapter.translate_block(revision, block, checkpoint)
    assert client.calls[0] == client.calls[1]
    assert [m["role"] for m in client.calls[0]] == ["system", "user", "user"]


def test_protocol_error_is_retried_within_budget_then_succeeds(tmp_path: Path) -> None:
    sleeps: list[float] = []
    client = FakeDeepSeekApiClient()
    adapter = _adapter(
        tmp_path, client, max_retries=2, sleeper=lambda delay: sleeps.append(delay)
    )
    block = _block("b0", 0, ["One."])
    revision = _revision([block])
    checkpoint = adapter.begin(revision)

    client.queue(_completion('["extra", "items"]'))  # wrong length -> protocol error
    client.queue(_completion('["一。"]'))  # valid on retry
    batch = adapter.translate_block(revision, block, checkpoint)

    assert [t.text_zh for t in batch.translations] == ["一。"]
    assert len(sleeps) == 1  # one retry after the malformed first response
    assert len(client.calls) == 2


def test_non_array_and_empty_member_responses_are_rejected(tmp_path: Path) -> None:
    block = _block("b0", 0, ["One.", "Two."])
    revision = _revision([block])

    for bad_content in ('{"translations": ["一。", "二。"]}', "not json", '["一。", ""]'):
        client = FakeDeepSeekApiClient()
        adapter = _adapter(tmp_path, client, max_retries=0)
        checkpoint = adapter.begin(revision)
        client.queue(_completion(bad_content))
        with pytest.raises(TranslationProtocolError):
            adapter.translate_block(revision, block, checkpoint)


def test_transient_errors_retry_without_compressing_context(tmp_path: Path) -> None:
    sleeps: list[float] = []
    client = FakeDeepSeekApiClient()
    adapter = _adapter(
        tmp_path, client, max_retries=2, sleeper=lambda delay: sleeps.append(delay)
    )
    block = _block("b0", 0, ["One."])
    revision = _revision([block])
    checkpoint = adapter.begin(revision)

    client.queue(TranslationRateLimitError("throttled"))
    client.queue(TranslationServerError("boom"))
    client.queue(_completion('["一。"]'))

    batch = adapter.translate_block(revision, block, checkpoint)

    assert [t.text_zh for t in batch.translations] == ["一。"]
    assert len(sleeps) == 2
    assert len(client.calls) == 3
    # Every retry replays the identical, uncompressed message list.
    assert client.calls[0] == client.calls[1] == client.calls[2]


def test_exhausted_transient_retries_raise(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=1)
    block = _block("b0", 0, ["One."])
    revision = _revision([block])
    checkpoint = adapter.begin(revision)

    client.queue(TranslationRateLimitError("throttled"))
    client.queue(TranslationRateLimitError("throttled"))

    with pytest.raises(TranslationRateLimitError):
        adapter.translate_block(revision, block, checkpoint)
    assert len(client.calls) == 2  # initial + 1 retry


def test_non_transient_error_is_not_retried(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=3)
    block = _block("b0", 0, ["One."])
    revision = _revision([block])
    checkpoint = adapter.begin(revision)
    client.queue(TranslationAuthError("bad key"))

    with pytest.raises(TranslationAuthError):
        adapter.translate_block(revision, block, checkpoint)
    assert len(client.calls) == 1


def test_missing_client_raises_configuration_error(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path, client=None)
    block = _block("b0", 0, ["One."])
    revision = _revision([block])
    checkpoint = adapter.begin(revision)  # begin needs no client

    with pytest.raises(DeepSeekConfigurationError):
        adapter.translate_block(revision, block, checkpoint)
    with pytest.raises(DeepSeekConfigurationError):
        adapter.verify_access()


def test_missing_journal_raises_protocol_error(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    block = _block("b0", 0, ["One."])

    with pytest.raises(TranslationProtocolError):
        adapter.translate_block(_revision([block]), block, "never-begun")


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


def test_cross_instance_resume_rebuilds_history_from_journal(tmp_path: Path) -> None:
    block0 = _block("b0", 0, ["First."])
    block1 = _block("b1", 1, ["Second."])
    revision = _revision([block0, block1])

    client_a = FakeDeepSeekApiClient()
    adapter_a = _adapter(tmp_path, client_a)
    checkpoint = adapter_a.begin(revision)
    client_a.queue(_completion('["第一句。"]'))
    adapter_a.translate_block(revision, block0, checkpoint)

    # A brand-new adapter instance (e.g. a restarted worker) loads the durable
    # journal and must replay block 0's accepted translation as context.
    client_b = FakeDeepSeekApiClient()
    adapter_b = _adapter(tmp_path, client_b)
    client_b.queue(_completion('["第二句。"]'))
    adapter_b.translate_block(revision, block1, checkpoint)

    messages = client_b.calls[0]
    assert [m["role"] for m in messages] == ["system", "user", "user", "assistant", "user"]
    assert json.loads(messages[3]["content"]) == ["第一句。"]


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


def test_fenced_and_bom_responses_are_parsed(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    block = _block("b0", 0, ["One.", "Two."])
    revision = _revision([block])
    checkpoint = adapter.begin(revision)

    fenced = "```json\n[\"第一句。\", \"第二句。\"]\n```"
    bom = "﻿[\"甲。\", \"乙。\"]"
    client.queue(_completion(fenced))
    batch = adapter.translate_block(revision, block, checkpoint)
    assert [t.text_zh for t in batch.translations] == ["第一句。", "第二句。"]

    client.queue(_completion(bom))
    batch = adapter.translate_block(revision, block, checkpoint)
    assert [t.text_zh for t in batch.translations] == ["甲。", "乙。"]


def test_three_blocks_accumulate_two_accepted_assistant_turns(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client)
    blocks = [_block("b0", 0, ["A."]), _block("b1", 1, ["B."]), _block("b2", 2, ["C."])]
    revision = _revision(blocks)
    checkpoint = adapter.begin(revision)

    for block, zh in zip(blocks, ('["甲。"]', '["乙。"]', '["丙。"]'), strict=True):
        client.queue(_completion(zh))
        adapter.translate_block(revision, block, checkpoint)

    third_messages = client.calls[2]
    # system + source + (user b0, assistant b0) + (user b1, assistant b1) + user b2
    assert [m["role"] for m in third_messages] == [
        "system", "user", "user", "assistant", "user", "assistant", "user",
    ]
    # The full-article source context is present and structured (not empty).
    assert json.loads(third_messages[1]["content"])["title"] == revision.title
    assert json.loads(third_messages[3]["content"]) == ["甲。"]
    assert json.loads(third_messages[5]["content"]) == ["乙。"]


def test_block_not_in_revision_is_rejected(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=0)
    block0 = _block("b0", 0, ["One."])
    revision = _revision([block0])
    checkpoint = adapter.begin(revision)
    client.queue(_completion('["一。"]'))
    adapter.translate_block(revision, block0, checkpoint)

    rogue = _block("rogue", 1, ["X."])
    with pytest.raises(TranslationProtocolError):
        adapter.translate_block(revision, rogue, checkpoint)


def test_stale_journal_is_rejected_on_resume(tmp_path: Path) -> None:
    client = FakeDeepSeekApiClient()
    adapter = _adapter(tmp_path, client, max_retries=0)
    block = _block("b0", 0, ["One."])
    revision = _revision([block])
    checkpoint = adapter.begin(revision)

    # Reuse the checkpoint against a different revision (different title => different
    # source hash) as could happen if a checkpoint id were ever reused.
    other_revision = replace(revision, title="A Different Article")
    with pytest.raises(TranslationProtocolError):
        adapter.translate_block(other_revision, block, checkpoint)


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


def test_map_api_error_translates_real_openai_exceptions() -> None:
    assert isinstance(_map_api_error(_api_status_error(401, "nope")), TranslationAuthError)
    assert isinstance(_map_api_error(_api_status_error(402, "nope")), TranslationQuotaError)
    assert isinstance(_map_api_error(_api_status_error(429, "nope")), TranslationRateLimitError)
    assert isinstance(_map_api_error(_api_status_error(500, "nope")), TranslationServerError)
    request = httpx.Request("POST", "https://api.deepseek.com/chat/completions")
    assert isinstance(_map_api_error(APITimeoutError(request=request)), TranslationTimeoutError)
