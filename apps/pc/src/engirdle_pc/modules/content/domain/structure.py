from __future__ import annotations

import json
from collections.abc import Iterable
from dataclasses import replace

from engirdle_pc.modules.content.domain.entities import (
    Block,
    CodeBlock,
    DividerBlock,
    EditedBlock,
    EditedCodeBlock,
    EditedDividerBlock,
    EditedTableBlock,
    EditedTextBlock,
    InlineRun,
    Sentence,
    TableBlock,
    TableCell,
    TextBlock,
    TextBlockStyle,
)
from engirdle_pc.modules.content.domain.errors import InvalidContent
from engirdle_pc.shared.domain.hashing import sha256_text

# Versioned identifier for the segmentation algorithm owned by this module. A
# change to segmentation MUST bump this so the published manifest records which
# segmenter produced the structure, and stored structure hashes stay traceable
# to the algorithm revision that produced them. Bumped to @2 with the markdown
# document model: sentences are now spans of visible plain text with inline
# runs sliced to match (design §5.3).
SEGMENTER_VERSION = "engirdle-segmenter@2"


def structure_sha256(blocks: Iterable[Block]) -> str:
    """Canonical structure hash over the typed block union (design §5.2.9).

    Covers block types, type-specific fields, sentences, inline runs, table
    structure and code content so any structural change alters the hash.
    """
    payload = [_block_payload(block) for block in blocks]
    canonical = json.dumps(
        payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    )
    return sha256_text(canonical)


def _block_payload(block: Block) -> dict[str, object]:
    base: dict[str, object] = {
        "block_id": block.block_id,
        "kind": block.kind.value,
        "order": block.order,
    }
    if isinstance(block, TextBlock):
        base["style"] = block.style.value
        if block.heading_level is not None:
            base["heading_level"] = block.heading_level
        if block.list_kind is not None:
            base["list_kind"] = block.list_kind.value
            base["list_depth"] = block.list_depth
        if block.list_ordinal is not None:
            base["list_ordinal"] = block.list_ordinal
        if block.quote_depth:
            base["quote_depth"] = block.quote_depth
        base["sentences"] = [
            {
                "sentence_id": sentence.sentence_id,
                "order": sentence.order,
                "text": sentence.text,
                "runs": [
                    {
                        "kind": run.kind.value,
                        "text": run.text,
                        **({"href": run.href} if run.href is not None else {}),
                    }
                    for run in sentence.runs
                ],
            }
            for sentence in block.sentences
        ]
    elif isinstance(block, TableBlock):
        base["alignments"] = [alignment.value for alignment in block.alignments]
        base["header"] = [_cell_payload(cell) for cell in block.header]
        base["rows"] = [[_cell_payload(cell) for cell in row] for row in block.rows]
    elif isinstance(block, CodeBlock):
        base["language"] = block.language
        base["code"] = block.code
    return base


def _cell_payload(cell: TableCell) -> dict[str, object]:
    return {
        "cell_id": cell.cell_id,
        "text": cell.plain_text,
        "runs": [
            {
                "kind": run.kind.value,
                "text": run.text,
                **({"href": run.href} if run.href is not None else {}),
            }
            for run in cell.runs
        ],
    }


def materialize_edited_blocks(edited_blocks: Iterable[EditedBlock]) -> tuple[Block, ...]:
    """Validate a typed structure edit and assign any missing stable IDs.

    ID policy (design §11.2): identifiers left empty are allocated here by the
    content module — entrypoints never mint their own IDs.
    """
    edited = tuple(edited_blocks)
    provided_block_ids = [block.block_id for block in edited if block.block_id is not None]
    provided_sentence_ids = [
        sentence.sentence_id
        for block in edited
        if isinstance(block, EditedTextBlock)
        for sentence in block.sentences
        if sentence.sentence_id is not None
    ]
    if len(provided_block_ids) != len(set(provided_block_ids)):
        raise InvalidContent("duplicate provided block ID")
    if len(provided_sentence_ids) != len(set(provided_sentence_ids)):
        raise InvalidContent("duplicate provided sentence ID")
    blocks: list[Block] = []
    used_block_ids: set[str] = set()
    used_sentence_ids: set[str] = set()
    used_cell_ids: set[str] = set()
    next_block_number = 1
    next_sentence_number = 1
    next_cell_number = 1
    for block_order, edited_block in enumerate(edited):
        while (
            f"block-{next_block_number}" in used_block_ids
            or f"block-{next_block_number}" in provided_block_ids
        ):
            next_block_number += 1
        block_id = edited_block.block_id or f"block-{next_block_number}"
        next_block_number += 1
        if block_id in used_block_ids:
            raise InvalidContent(f"duplicate block ID: {block_id}")
        used_block_ids.add(block_id)
        if isinstance(edited_block, EditedTextBlock):
            sentences: list[Sentence] = []
            for sentence_order, edited_sentence in enumerate(edited_block.sentences):
                text = edited_sentence.text.strip()
                if not text:
                    raise InvalidContent("sentences must not be empty")
                while (
                    f"sentence-{next_sentence_number}" in used_sentence_ids
                    or f"sentence-{next_sentence_number}" in provided_sentence_ids
                ):
                    next_sentence_number += 1
                sentence_id = (
                    edited_sentence.sentence_id or f"sentence-{next_sentence_number}"
                )
                next_sentence_number += 1
                if sentence_id in used_sentence_ids:
                    raise InvalidContent(f"duplicate sentence ID: {sentence_id}")
                used_sentence_ids.add(sentence_id)
                sentences.append(Sentence(sentence_id, sentence_order, text))
            if not sentences:
                raise InvalidContent("text blocks must contain at least one sentence")
            blocks.append(
                TextBlock(
                    block_id=block_id,
                    order=block_order,
                    style=edited_block.style,
                    sentences=tuple(sentences),
                    heading_level=edited_block.heading_level,
                    list_kind=edited_block.list_kind,
                    list_depth=edited_block.list_depth,
                    list_ordinal=edited_block.list_ordinal,
                    quote_depth=edited_block.quote_depth,
                )
            )
        elif isinstance(edited_block, EditedTableBlock):
            columns = len(edited_block.header)
            if columns == 0:
                raise InvalidContent("table blocks must have a header row")
            if len(edited_block.alignments) != columns:
                raise InvalidContent("table alignment count must match the header")
            header: list[TableCell] = []
            rows: list[tuple[TableCell, ...]] = []
            def make_cell(text: str) -> TableCell:
                nonlocal next_cell_number
                cell_id = f"cell-{next_cell_number}"
                next_cell_number += 1
                if cell_id in used_cell_ids:
                    raise InvalidContent(f"duplicate cell ID: {cell_id}")
                used_cell_ids.add(cell_id)
                return TableCell(cell_id=cell_id, plain_text=text.strip())

            header = [make_cell(text) for text in edited_block.header]
            for row in edited_block.rows:
                if len(row) != columns:
                    raise InvalidContent("table rows must match the header width")
                rows.append(tuple(make_cell(text) for text in row))
            blocks.append(
                TableBlock(
                    block_id=block_id,
                    order=block_order,
                    alignments=tuple(edited_block.alignments),
                    header=tuple(header),
                    rows=tuple(rows),
                )
            )
        elif isinstance(edited_block, EditedCodeBlock):
            code = edited_block.code
            if not code:
                raise InvalidContent("code blocks must not be empty")
            blocks.append(
                CodeBlock(
                    block_id=block_id,
                    order=block_order,
                    code=code,
                    language=edited_block.language,
                )
            )
        elif isinstance(edited_block, EditedDividerBlock):
            blocks.append(DividerBlock(block_id=block_id, order=block_order))
        else:
            raise InvalidContent(f"unsupported edited block: {type(edited_block).__name__}")
    if not blocks:
        raise InvalidContent("article must contain at least one block")
    return tuple(blocks)


def text_block_plain_runs(text: str) -> tuple[InlineRun, ...]:
    """Single plain run projection used when only plain text is available."""
    from engirdle_pc.modules.content.domain.entities import InlineRunKind

    return (InlineRun(InlineRunKind.PLAIN, text),)


def normalize_edited_text_block_styles(block: TextBlock) -> TextBlock:
    """Keep edited heading/quote styles consistent after direct construction."""
    if block.style is TextBlockStyle.HEADING and block.heading_level is None:
        return replace(block, heading_level=1)
    return block
