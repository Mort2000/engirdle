from __future__ import annotations

from pathlib import Path

import pytest

from engirdle_pc.modules.translation.infrastructure.deepseek_errors import (
    TranslationProtocolError,
)
from engirdle_pc.modules.translation.infrastructure.session_journal import (
    TranslationSessionJournal,
)


def test_create_then_load_round_trips_accepted_units(tmp_path: Path) -> None:
    directory = tmp_path / "translation_sessions"

    TranslationSessionJournal.create(
        directory=directory,
        checkpoint_id="ckpt-1",
        source_sha256="abc",
        prompt_version="full-article-sequential-units@v2",
    )
    journal = TranslationSessionJournal.load(directory, "ckpt-1")
    assert journal is not None
    assert journal.accepted == {}

    journal.accept_unit("b0", '["第一句。", "第二句。"]')
    journal.accept_unit("table-1", '{"block_id": "table-1", "cells": []}')

    reloaded = TranslationSessionJournal.load(directory, "ckpt-1")
    assert reloaded is not None
    assert reloaded.accepted == {
        "b0": '["第一句。", "第二句。"]',
        "table-1": '{"block_id": "table-1", "cells": []}',
    }
    assert reloaded.source_sha256 == "abc"
    assert reloaded.prompt_version == "full-article-sequential-units@v2"


def test_load_returns_none_when_journal_missing(tmp_path: Path) -> None:
    assert TranslationSessionJournal.load(tmp_path, "missing") is None


def test_accept_unit_overwrites_on_retry(tmp_path: Path) -> None:
    directory = tmp_path / "translation_sessions"
    journal = TranslationSessionJournal.create(
        directory=directory,
        checkpoint_id="ckpt-2",
        source_sha256="abc",
        prompt_version="v1",
    )
    journal.accept_unit("b0", '["旧翻译"]')
    journal.accept_unit("b0", '["新翻译"]')

    reloaded = TranslationSessionJournal.load(directory, "ckpt-2")
    assert reloaded is not None
    assert reloaded.accepted["b0"] == '["新翻译"]'


def test_corrupt_journal_raises_typed_protocol_error(tmp_path: Path) -> None:
    directory = tmp_path / "translation_sessions"
    directory.mkdir(parents=True)
    (directory / "ckpt-x.json").write_text("{not valid json", encoding="utf-8")

    with pytest.raises(TranslationProtocolError):
        TranslationSessionJournal.load(directory, "ckpt-x")


def test_schema_drift_journal_raises_typed_protocol_error(tmp_path: Path) -> None:
    directory = tmp_path / "translation_sessions"
    directory.mkdir(parents=True)
    # Valid JSON but missing required keys (e.g. an older journal schema).
    (directory / "ckpt-y.json").write_text('{"unrelated": true}', encoding="utf-8")

    with pytest.raises(TranslationProtocolError):
        TranslationSessionJournal.load(directory, "ckpt-y")
