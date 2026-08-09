from __future__ import annotations

import json
from pathlib import Path
from typing import Any, cast

import pytest
from jsonschema import Draft202012Validator, FormatChecker  # type: ignore[import-untyped]

from engirdle_pc.bootstrap.config import Settings


def test_pc_accepts_shared_valid_dictionary_manifest_fixture() -> None:
    errors = _validation_errors(_fixture("valid/minimal.json"))

    assert errors == []


@pytest.mark.parametrize(
    "fixture_name",
    ["unsupported-major.json", "wrong-source-set.json"],
)
def test_pc_rejects_shared_invalid_dictionary_manifest_fixtures(
    fixture_name: str,
) -> None:
    errors = _validation_errors(_fixture(f"invalid/{fixture_name}"))

    assert errors


def _fixture(relative: str) -> Path:
    return Settings().contracts_dir / "dictionary/v2/fixtures" / relative


def _validation_errors(fixture: Path) -> list[Any]:
    contracts = Settings().contracts_dir
    schema = cast(
        dict[str, Any],
        json.loads(
            (contracts / "dictionary/v2/schema/manifest.schema.json").read_text(encoding="utf-8")
        ),
    )
    document = json.loads(fixture.read_text(encoding="utf-8"))
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    return list(validator.iter_errors(document))
