"""Shared translation-v1 contract tests.

The contract under contracts/translation/v1 freezes the PC translation
protocol (prompt, constants, wire shapes, placeholder rules, golden message
projection). These tests prove the extraction changed nothing: the PC
implementation must reproduce every frozen artifact byte for byte, and must
accept/reject the shared response fixtures exactly as documented.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.modules.translation.application import dto
from engirdle_pc.modules.translation.application.dto import (
    build_source_context,
    build_system_prompt,
    build_unit_request,
    parse_translation_list,
    unit_protected_map,
)
from engirdle_pc.modules.translation.application.service import (
    _MAX_TRANSLATION_LENGTH,
)
from engirdle_pc.modules.translation.infrastructure.chat_client import (
    OFFICIAL_ENDPOINT,
    CompletionResult,
)
from engirdle_pc.modules.translation.infrastructure.deepseek_adapter import (
    DeepSeekTranslationAdapter,
)
from engirdle_pc.modules.translation.infrastructure.deepseek_errors import (
    TranslationProtocolError,
)

from .golden_article import load_golden_plan

TRANSLATION_CONTRACT = "translation/v1"


def _contracts() -> Path:
    return Settings().contracts_dir


def _fixture(relative: str) -> str:
    return (_contracts() / TRANSLATION_CONTRACT / relative).read_text(encoding="utf-8")


def test_protocol_constants_match_shared_contract() -> None:
    protocol = json.loads(_fixture("protocol.json"))

    assert protocol["prompt_version"] == dto.PROMPT_VERSION
    assert protocol["thinking_mode"] == dto.THINKING_MODE
    assert protocol["reasoning_effort"] == dto.REASONING_EFFORT
    assert protocol["max_translation_chars"] == _MAX_TRANSLATION_LENGTH


def test_system_prompt_matches_shared_contract_byte_for_byte() -> None:
    frozen = (_contracts() / TRANSLATION_CONTRACT / "system_prompt.txt").read_bytes()

    assert frozen.decode("utf-8") == build_system_prompt()


def test_golden_article_projects_to_expected_messages() -> None:
    revision, plan = load_golden_plan(_contracts())
    expected = json.loads(_fixture("fixtures/golden/expected_messages.json"))

    assert build_system_prompt() == expected["system"]
    assert build_source_context(revision, plan) == expected["source_context"]
    assert [build_unit_request(unit) for unit in plan.translation.units] == [
        request for request in expected["unit_requests"]
    ]


@pytest.mark.parametrize(
    ("fixture", "block_id"),
    [
        ("fixtures/responses/valid/sentence-array.json", "block-1"),
        ("fixtures/responses/valid/table-object.json", "block-3"),
    ],
)
def test_valid_response_fixtures_pass_protocol_validation(
    fixture: str, block_id: str, tmp_path: Path
) -> None:
    adapter = _adapter(tmp_path)
    unit = _unit(block_id)

    accepted = adapter._validate(
        CompletionResult(
            content=_fixture(fixture), finish_reason="stop", request_id="req", usage=None
        ),
        unit,
        unit_protected_map(unit),
    )

    assert accepted.translation.block_id == block_id


def test_fenced_sentence_response_strips_to_same_parse(tmp_path: Path) -> None:
    plain = _fixture("fixtures/responses/valid/sentence-array.json")
    fenced = _fixture("fixtures/responses/valid/sentence-fenced.txt")

    assert parse_translation_list(fenced) == parse_translation_list(plain)


@pytest.mark.parametrize(
    ("fixture", "block_id"),
    [
        ("fixtures/responses/invalid/sentence-wrong-length.json", "block-1"),
        ("fixtures/responses/invalid/sentence-empty-item.json", "block-1"),
        ("fixtures/responses/invalid/prose-wrapped.txt", "block-1"),
        ("fixtures/responses/invalid/table-cell-added.json", "block-3"),
        ("fixtures/responses/invalid/table-damaged-placeholder.txt", "block-3"),
    ],
)
def test_invalid_response_fixtures_are_rejected(
    fixture: str, block_id: str, tmp_path: Path
) -> None:
    adapter = _adapter(tmp_path)
    unit = _unit(block_id)

    with pytest.raises(TranslationProtocolError):
        adapter._validate(
            CompletionResult(
                content=_fixture(fixture),
                finish_reason="stop",
                request_id="req",
                usage=None,
            ),
            unit,
            unit_protected_map(unit),
        )


def _adapter(tmp_path: Path) -> DeepSeekTranslationAdapter:
    return DeepSeekTranslationAdapter(
        client=None,
        endpoint=OFFICIAL_ENDPOINT,
        model="deepseek-chat",
        session_dir=tmp_path,
        identifiers=_Identifiers(),
    )


class _Identifiers:
    def new(self) -> str:
        return "id"


def _unit(block_id: str):
    _, plan = load_golden_plan(_contracts())
    for unit in plan.translation.units:
        if unit.unit_id == block_id:
            return unit
    raise KeyError(block_id)
