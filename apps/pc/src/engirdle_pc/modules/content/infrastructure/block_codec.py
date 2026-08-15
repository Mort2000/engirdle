"""Persistence seam codecs for the typed block union (design §12.1).

JSON exists ONLY at this repository boundary: rows carry plain columns for
identity/order queries plus one payload document per block and one render
document per sentence. The DAO decodes back into typed dataclasses
immediately; no module above this file ever sees a raw dict.
"""

from __future__ import annotations

import json
from typing import Any

from engirdle_pc.modules.content.domain.entities import (
    Block,
    BlockKind,
    CodeBlock,
    DividerBlock,
    InlineRun,
    InlineRunKind,
    ListKind,
    Sentence,
    TableAlignment,
    TableBlock,
    TableCell,
    TextBlock,
    TextBlockStyle,
)
from engirdle_pc.modules.content.domain.errors import InvalidContent


def block_payload(block: Block) -> str:
    if isinstance(block, TextBlock):
        payload: dict[str, Any] = {"style": block.style.value}
        if block.heading_level is not None:
            payload["heading_level"] = block.heading_level
        if block.list_kind is not None:
            payload["list_kind"] = block.list_kind.value
            payload["list_depth"] = block.list_depth
        if block.list_ordinal is not None:
            payload["list_ordinal"] = block.list_ordinal
        if block.quote_depth:
            payload["quote_depth"] = block.quote_depth
    elif isinstance(block, TableBlock):
        payload = {
            "alignments": [alignment.value for alignment in block.alignments],
            "header": [_cell_json(cell) for cell in block.header],
            "rows": [[_cell_json(cell) for cell in row] for row in block.rows],
        }
    elif isinstance(block, CodeBlock):
        payload = {"code": block.code, "language": block.language}
    else:
        payload = {}
    return json.dumps(payload, ensure_ascii=False, sort_keys=True)


def block_from_row(
    kind: str, block_id: str, order: int, payload_json: str, sentences: list[Sentence]
) -> Block:
    payload: dict[str, Any] = json.loads(payload_json) if payload_json else {}
    try:
        parsed_kind = BlockKind(kind)
    except ValueError as error:
        raise InvalidContent(f"unknown stored block kind: {kind}") from error
    if parsed_kind in {
        BlockKind.PARAGRAPH,
        BlockKind.LIST_ITEM,
        BlockKind.QUOTE,
        BlockKind.HEADING,
    }:
        style = TextBlockStyle(payload.get("style", parsed_kind.value))
        return TextBlock(
            block_id=block_id,
            order=order,
            style=style,
            sentences=tuple(sentences),
            heading_level=payload.get("heading_level"),
            list_kind=ListKind(payload["list_kind"]) if "list_kind" in payload else None,
            list_depth=int(payload.get("list_depth", 0)),
            list_ordinal=payload.get("list_ordinal"),
            quote_depth=int(payload.get("quote_depth", 1 if style is TextBlockStyle.QUOTE else 0)),
        )
    if parsed_kind is BlockKind.TABLE:
        return TableBlock(
            block_id=block_id,
            order=order,
            alignments=tuple(
                TableAlignment(value) for value in payload.get("alignments", [])
            ),
            header=tuple(_cell_from_json(cell) for cell in payload.get("header", [])),
            rows=tuple(
                tuple(_cell_from_json(cell) for cell in row)
                for row in payload.get("rows", [])
            ),
        )
    if parsed_kind is BlockKind.CODE:
        return CodeBlock(
            block_id=block_id,
            order=order,
            code=payload.get("code", ""),
            language=payload.get("language"),
        )
    return DividerBlock(block_id=block_id, order=order)


def sentence_render(sentence: Sentence) -> str:
    return json.dumps(_runs_json(sentence.runs), ensure_ascii=False)


def runs_from_render(render_json: str | None) -> tuple[InlineRun, ...]:
    if not render_json:
        return ()
    return tuple(_run_from_json(item) for item in json.loads(render_json))


def _cell_json(cell: TableCell) -> dict[str, Any]:
    return {
        "cell_id": cell.cell_id,
        "text": cell.plain_text,
        "runs": _runs_json(cell.runs),
    }


def _cell_from_json(payload: dict[str, Any]) -> TableCell:
    return TableCell(
        cell_id=payload["cell_id"],
        plain_text=payload.get("text", ""),
        runs=tuple(_run_from_json(item) for item in payload.get("runs", [])),
    )


def _runs_json(runs: tuple[InlineRun, ...]) -> list[dict[str, Any]]:
    return [
        {
            "kind": run.kind.value,
            "text": run.text,
            **({"href": run.href} if run.href is not None else {}),
        }
        for run in runs
    ]


def _run_from_json(payload: dict[str, Any]) -> InlineRun:
    return InlineRun(
        kind=InlineRunKind(payload["kind"]),
        text=payload.get("text", ""),
        href=payload.get("href"),
    )
