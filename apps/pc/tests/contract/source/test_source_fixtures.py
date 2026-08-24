"""The shared source-parsing gold fixtures (contracts/source/v1).

The expected files are generated from this pipeline by
``contracts/source/v1/tools/generate_fixtures.py``; this test pins that the
frozen expectations keep matching PC behavior. The mobile Dart parser runs the
same corpus (``apps/mobile/test/contracts/source_fixtures_test.dart``) — a
contract change must update both implementations in the same change
(contracts/README.md).
"""

import importlib.util
import json
import sys
from pathlib import Path

import pytest

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.modules.content.domain.errors import (
    MarkdownResourceLimit,
    UnsupportedMarkdown,
)
from engirdle_pc.modules.content.domain.markdown import parse_markdown


def _generator():
    """Loads the fixture generator (the single dumper both sides share)."""
    path = Settings().contracts_dir / "source/v1/tools/generate_fixtures.py"
    spec = importlib.util.spec_from_file_location("engirdle_source_fixture_gen", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize(
    "fixture",
    sorted(
        (Settings().contracts_dir / "source/v1/fixtures").glob("*.md"),
        key=lambda path: path.name,
    ),
    ids=lambda path: path.name,
)
def test_pc_parse_matches_frozen_expectation(fixture: Path) -> None:
    expected = json.loads(
        (fixture.parent / "expected" / f"{fixture.stem}.json").read_text(encoding="utf-8")
    )
    assert _generator().generate(fixture.read_text(encoding="utf-8")) == expected


@pytest.mark.parametrize(
    "fixture",
    sorted(
        (Settings().contracts_dir / "source/v1/fixtures/reject").glob("*.md"),
        key=lambda path: path.name,
    ),
    ids=lambda path: path.name,
)
def test_pc_rejects_frozen_reject_fixtures(fixture: Path) -> None:
    expected = json.loads(
        (fixture.parent.parent / "expected" / f"reject-{fixture.stem}.json").read_text(
            encoding="utf-8"
        )
    )
    with pytest.raises((UnsupportedMarkdown, MarkdownResourceLimit)) as raised:
        parse_markdown(fixture.read_text(encoding="utf-8"))
    assert type(raised.value).__name__ == expected["error"]
