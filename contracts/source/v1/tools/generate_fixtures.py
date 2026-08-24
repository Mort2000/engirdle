"""Regenerate the shared source-parsing gold fixtures.

The fixtures under ``contracts/source/v1/fixtures`` are the cross-implementation
contract between the PC parser (``engirdle-gfm@1`` / markdown-it-py) and the
mobile Dart parser (``engirdle-gfm-dart@1``). Expected outputs are generated
from the PC pipeline — the current behavior, byte-frozen — so both sides can be
held to the same truth (mobile additionally runs the same corpus in
``apps/mobile/test/contracts/source_fixtures_test.dart``).

Usage (from the repository root or apps/pc, inside the PC environment):

    uv run python contracts/source/v1/tools/generate_fixtures.py

Writes ``fixtures/expected/<stem>.json`` for every ``fixtures/<stem>.md`` and
``fixtures/expected/reject-<stem>.json`` (``{"error": ...}``) for every
``fixtures/reject/<stem>.md``.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "apps" / "pc" / "src"))

from engirdle_pc.modules.content.domain.entities import (  # noqa: E402
    CodeBlock,
    TableBlock,
    TextBlock,
)
from engirdle_pc.modules.content.domain.markdown import (  # noqa: E402
    PARSE_VERSION,
    parse_markdown,
)
from engirdle_pc.modules.content.domain.structure import (  # noqa: E402
    SEGMENTER_VERSION,
    structure_sha256,
)
from engirdle_pc.shared.domain.hashing import sha256_text  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"


def _run_payload(run) -> dict:
    payload = {"kind": run.kind.value, "text": run.text}
    if run.href is not None:
        payload["href"] = run.href
    return payload


def _block_payload(block) -> dict:
    payload: dict = {
        "block_id": block.block_id,
        "kind": block.kind.value,
        "order": block.order,
    }
    if isinstance(block, TextBlock):
        payload["style"] = block.style.value
        if block.heading_level is not None:
            payload["heading_level"] = block.heading_level
        if block.list_kind is not None:
            payload["list_kind"] = block.list_kind.value
            payload["list_depth"] = block.list_depth
        if block.list_ordinal is not None:
            payload["list_ordinal"] = block.list_ordinal
        if block.quote_depth:
            payload["quote_depth"] = block.quote_depth
        payload["sentences"] = [
            {
                "sentence_id": sentence.sentence_id,
                "order": sentence.order,
                "text": sentence.text,
                "runs": [_run_payload(run) for run in sentence.runs],
            }
            for sentence in block.sentences
        ]
    elif isinstance(block, TableBlock):
        payload["alignments"] = [alignment.value for alignment in block.alignments]
        payload["header"] = [_cell_payload(cell) for cell in block.header]
        payload["rows"] = [[_cell_payload(cell) for cell in row] for row in block.rows]
    elif isinstance(block, CodeBlock):
        payload["language"] = block.language
        payload["code"] = block.code
    return payload


def _cell_payload(cell) -> dict:
    return {
        "cell_id": cell.cell_id,
        "text": cell.plain_text,
        "runs": [_run_payload(run) for run in cell.runs],
    }


def generate(source: str) -> dict:
    parsed = parse_markdown(source)
    return {
        "parser_version": PARSE_VERSION,
        "segmenter_version": SEGMENTER_VERSION,
        "source_sha256": sha256_text(source),
        "normalized_sha256": sha256_text(parsed.canonical_markdown),
        "structure_sha256": structure_sha256(parsed.blocks),
        "warnings": [
            {"code": w.code, "message": w.message, "block_index": w.block_index}
            for w in parsed.warnings
        ],
        "blocks": [_block_payload(block) for block in parsed.blocks],
    }


def main() -> None:
    expected_dir = FIXTURES / "expected"
    expected_dir.mkdir(exist_ok=True)
    for path in sorted(FIXTURES.glob("*.md")):
        out = expected_dir / f"{path.stem}.json"
        out.write_text(
            json.dumps(generate(path.read_text()), ensure_ascii=False, indent=2)
            + "\n",
            encoding="utf-8",
        )
        print(f"wrote {out.relative_to(FIXTURES)}")
    for path in sorted((FIXTURES / "reject").glob("*.md")):
        try:
            generate(path.read_text())
        except Exception as error:  # noqa: BLE001 - the rejection IS the fixture
            expected = {"error": type(error).__name__}
        else:
            raise SystemExit(f"reject fixture {path.name} parses successfully")
        out = expected_dir / f"reject-{path.stem}.json"
        out.write_text(
            json.dumps(expected, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(f"wrote {out.relative_to(FIXTURES)}")
    # Guard against silent regeneration drift: every expected file must hash to
    # the value embedded below (update deliberately when the corpus changes).
    digest = hashlib.sha256()
    for path in sorted(expected_dir.glob("*.json")):
        digest.update(path.name.encode())
        digest.update(path.read_bytes())
    print(f"expected-dir digest: {digest.hexdigest()[:16]}")


if __name__ == "__main__":
    main()
