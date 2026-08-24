"""Loader for the shared translation-v1 golden article fixture.

Deserializes the language-neutral golden article JSON (contracts/
translation/v1/fixtures/golden/article.json) into the PC domain entities so
both the contract tests and any fixture-regeneration tooling construct the
exact same ProcessingPlan. Mobile's Dart test constructs the equivalent plan
from the same JSON.
"""

from __future__ import annotations

import json
from pathlib import Path

from engirdle_pc.modules.content.domain.entities import (
    ArticleRevision,
    Block,
    CodeBlock,
    DividerBlock,
    InlineRun,
    InlineRunKind,
    ListKind,
    RevisionStatus,
    Sentence,
    SourceAttribution,
    TableAlignment,
    TableBlock,
    TableCell,
    TextBlock,
    TextBlockStyle,
)
from engirdle_pc.modules.content.domain.plan import ProcessingPlan

_TEXT_STYLES = {
    "paragraph": TextBlockStyle.PARAGRAPH,
    "list_item": TextBlockStyle.LIST_ITEM,
    "quote": TextBlockStyle.QUOTE,
    "heading": TextBlockStyle.HEADING,
}

GOLDEN_ARTICLE_ID = "44444444-4444-4444-8444-444444444444"


def _runs(items: list[dict[str, object]]) -> tuple[InlineRun, ...]:
    return tuple(
        InlineRun(
            kind=InlineRunKind(item["kind"]),  # type: ignore[arg-type]
            text=item["text"],
            href=item.get("href"),
        )
        for item in items
    )


def _block(data: dict[str, object], position: int) -> Block:
    kind = data["kind"]
    order = data.get("order", position)
    if kind in _TEXT_STYLES:
        sentences = tuple(
            Sentence(
                sentence_id=item["sentence_id"],
                order=item.get("order", index),
                text=item["text"],
                runs=_runs(item.get("runs", [])),
            )
            for index, item in enumerate(data["sentences"])
        )
        return TextBlock(
            block_id=data["block_id"],
            order=order,
            style=_TEXT_STYLES[kind],
            sentences=sentences,
            heading_level=data.get("level"),
            list_kind=(ListKind(data["list_kind"]) if "list_kind" in data else None),
            list_depth=data.get("list_depth", 0),
            list_ordinal=data.get("list_ordinal"),
            quote_depth=data.get("quote_depth", 0),
        )
    if kind == "table":

        def cell(item: dict[str, object]) -> TableCell:
            return TableCell(
                cell_id=item["cell_id"],
                plain_text=item["text"],
                runs=_runs(item.get("runs", [])),
            )

        return TableBlock(
            block_id=data["block_id"],
            order=order,
            alignments=tuple(TableAlignment(value) for value in data["alignments"]),
            header=tuple(cell(item) for item in data["header"]),
            rows=tuple(tuple(cell(item) for item in row) for row in data["rows"]),
        )
    if kind == "code":
        return CodeBlock(
            block_id=data["block_id"],
            order=order,
            code=data["code"],
            language=data.get("language"),
        )
    if kind == "divider":
        return DividerBlock(block_id=data["block_id"], order=order)
    raise ValueError(f"unknown golden block kind: {kind}")


def load_golden_plan(contracts_dir: Path) -> tuple[ArticleRevision, ProcessingPlan]:
    data = json.loads(
        (contracts_dir / "translation/v1/fixtures/golden/article.json").read_text(encoding="utf-8")
    )
    revision = ArticleRevision(
        article_id=GOLDEN_ARTICLE_ID,
        revision=1,
        title=data["title"],
        raw_text="",
        normalized_text="",
        source=SourceAttribution(
            author=data.get("author"),
            display_name=None,
            url=None,
            license_name="unknown",
        ),
        source_sha256="0" * 64,
        normalized_sha256="0" * 64,
        structure_sha256="0" * 64,
        status=RevisionStatus.STRUCTURED,
        blocks=tuple(_block(block, position) for position, block in enumerate(data["blocks"])),
    )
    return revision, ProcessingPlan.derive(revision)
