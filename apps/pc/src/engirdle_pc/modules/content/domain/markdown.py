"""Frozen-subset GFM parser producing the typed article document (design §4/§5).

This module is the ONLY place that understands markdown tokens. It walks the
markdown-it token stream once and emits the typed block union (TextBlock /
TableBlock / CodeBlock / DividerBlock) with inline runs, node-aware
normalization and span-accurate sentence splitting. Callers never see tokens,
offsets or library AST nodes.

Parsing policy (design §4.2/§4.3):
- raw HTML nodes fail parsing with `UnsupportedMarkdown` (they must never be
  published or silently passed through);
- images degrade to an IMAGE run showing the escaped alt text (plus a
  placeholder when there is no alt text); the URI never becomes a request;
- task-list markers stay part of the item text (non-interactive);
- an unclosed code fence only produces a warning — markdown-it's tolerant
  result stands, but the structure confirmation page shows it;
- tables that do not satisfy GFM rules stay paragraphs; nothing is repaired.

Resource limits (design §4.4) are enforced here, at freeze, and again by the
Readpack validator / mobile import via the same contract values.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field, replace

from markdown_it import MarkdownIt
from markdown_it.token import Token

from engirdle_pc.modules.content.domain.entities import (
    Block,
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
from engirdle_pc.modules.content.domain.errors import (
    MarkdownResourceLimit,
    UnsupportedMarkdown,
)

# Versioned identifier for the markdown projection (design §8.1). Bump on any
# markdown-it upgrade, enabled extension or AST projection change so stored
# structure hashes stay traceable to the parser revision that produced them.
PARSE_VERSION = "engirdle-gfm@1"

# Candidate stage-0 resource limits (design §4.4). Shared verbatim by the
# Readpack 1.1 schema and the mobile contract parser.


@dataclass(frozen=True)
class MarkdownLimits:
    max_blocks: int = 10_000
    max_nesting_depth: int = 4
    max_table_columns: int = 32
    max_table_rows: int = 256
    max_table_cell_characters: int = 4_000
    max_table_total_characters: int = 200_000
    max_code_block_bytes: int = 512 * 1024
    max_total_code_bytes: int = 2 * 1024 * 1024
    max_sentence_runs: int = 2_048
    # Wire-side caps shared with the Readpack article schema, so a revision
    # that could never be packaged is rejected at parse/freeze instead of
    # failing only at publish-time self-validation.
    max_block_sentences: int = 10_000
    max_sentence_characters: int = 20_000
    max_language_characters: int = 64
    max_link_href_characters: int = 2_048


DEFAULT_LIMITS = MarkdownLimits()


@dataclass(frozen=True)
class ParseWarning:
    """Non-fatal parse finding surfaced on the structure confirmation page."""

    code: str
    message: str
    block_index: int | None = None


@dataclass(frozen=True)
class ParsedMarkdown:
    canonical_markdown: str
    blocks: tuple[Block, ...]
    warnings: tuple[ParseWarning, ...] = ()


class _ParseCursor:
    """Sequential ID allocator shared across one document parse."""

    def __init__(self) -> None:
        self.block_number = 0
        self.sentence_number = 0

    def next_block_id(self) -> str:
        self.block_number += 1
        return f"block-{self.block_number}"

    def next_sentence_id(self) -> str:
        self.sentence_number += 1
        return f"sentence-{self.sentence_number}"

    @property
    def block_index(self) -> int:
        return self.block_number


@dataclass
class _Inline:
    """Visible plain text plus the run/offset mapping for one inline node."""

    text: str = ""
    runs: list[InlineRun] = field(default_factory=list)


_FENCE_LINE = re.compile(r"^( {0,3})(`{3,}|~{3,})")
_STYLE_PRIORITY = {
    InlineRunKind.CODE: 6,
    InlineRunKind.IMAGE: 5,
    InlineRunKind.LINK: 4,
    InlineRunKind.STRONG: 3,
    InlineRunKind.EMPHASIS: 2,
    InlineRunKind.STRIKETHROUGH: 1,
}
_SMART_CHARACTERS = str.maketrans(
    {
        "\u2018": "'",
        "\u2019": "'",
        "\u201c": '"',
        "\u201d": '"',
        "\u2013": "-",
        "\u2014": "--",
        "\u00a0": " ",
    }
)


def canonicalize_line_endings(raw: str) -> str:
    """The only whole-document normalization allowed before parsing (§8.1)."""
    return raw.replace("\r\n", "\n").replace("\r", "\n")


def _normalize_visible_text(text: str) -> str:
    """Project text policy for visible prose: NFKC, smart quotes, control filter.

    Deliberately NOT applied to code block bodies, inline code literals or link
    URIs (design §8.1).
    """
    normalized = unicodedata.normalize("NFKC", text).translate(_SMART_CHARACTERS)
    return "".join(
        character
        for character in normalized
        if character in "\n\t" or unicodedata.category(character) != "Cc"
    )


def build_parser() -> MarkdownIt:
    """The frozen GFM-subset parser instance (CommonMark + table + strikethrough)."""
    return MarkdownIt("commonmark").enable("table").enable("strikethrough")


def parse_markdown(
    raw_text: str, limits: MarkdownLimits = DEFAULT_LIMITS
) -> ParsedMarkdown:
    """Parse raw user input into the typed block document."""
    if not raw_text.strip():
        raise UnsupportedMarkdown("article body must not be empty")
    canonical = canonicalize_line_endings(raw_text)
    warnings: list[ParseWarning] = []
    tokens = build_parser().parse(canonical)
    cursor = _ParseCursor()
    blocks = list(
        _parse_tokens(
            tokens, 0, len(tokens), cursor, limits, warnings, quote_depth=0
        )
    )
    warnings.extend(_unclosed_fence_warnings(canonical, len(blocks)))
    if not blocks:
        raise UnsupportedMarkdown("article must contain at least one block")
    # Nested constructs (a list inside a list item) are built before their
    # parent block, so allocation order can differ from document order. The
    # published `order` is defined by document position (design §5.2.2), so
    # reassign it in one final pass.
    blocks = [replace(block, order=position) for position, block in enumerate(blocks)]
    if len(blocks) > limits.max_blocks:
        raise MarkdownResourceLimit(
            f"document has {len(blocks)} blocks; limit is {limits.max_blocks}"
        )
    _check_code_budget(blocks, limits)
    return ParsedMarkdown(
        canonical_markdown=canonical, blocks=tuple(blocks), warnings=tuple(warnings)
    )


# -- token walking ---------------------------------------------------------


def _parse_tokens(
    tokens: list[Token],
    start: int,
    end: int,
    cursor: _ParseCursor,
    limits: MarkdownLimits,
    warnings: list[ParseWarning],
    *,
    quote_depth: int,
    list_depth: int = 0,
) -> list[Block]:
    blocks: list[Block] = []
    index = start
    while index < end:
        token = tokens[index]
        block_index = cursor.block_index + 1
        if token.type == "heading_open":
            level = int(token.tag[1])
            inline = _inline(tokens[index + 1], limits, block_index)
            blocks.append(
                _text_block(
                    cursor,
                    style=TextBlockStyle.HEADING,
                    inline=inline,
                    limits=limits,
                    heading_level=level,
                )
            )
            index += 3
        elif token.type == "paragraph_open":
            inline = _inline(tokens[index + 1], limits, block_index)
            if inline.text.strip():
                blocks.append(
                    _text_block(
                        cursor,
                        style=(
                            TextBlockStyle.QUOTE
                            if quote_depth
                            else TextBlockStyle.PARAGRAPH
                        ),
                        inline=inline,
                        limits=limits,
                        quote_depth=quote_depth,
                    )
                )
            index += 3
        elif token.type == "fence":
            blocks.append(_code_block(cursor, token.content, token.info.strip() or None, limits))
            index += 1
        elif token.type == "code_block":
            blocks.append(_code_block(cursor, token.content, None, limits))
            index += 1
        elif token.type == "hr":
            blocks.append(DividerBlock(block_id=cursor.next_block_id(), order=cursor.block_index))
            index += 1
        elif token.type == "html_block":
            raise UnsupportedMarkdown(
                f"raw HTML is not supported (block position {block_index})"
            )
        elif token.type == "blockquote_open":
            close = _matching_close(tokens, index, end, "blockquote_open", "blockquote_close")
            if quote_depth + 1 > limits.max_nesting_depth:
                raise MarkdownResourceLimit(
                    f"blockquote nesting exceeds {limits.max_nesting_depth}"
                )
            blocks.extend(
                _parse_tokens(
                    tokens,
                    index + 1,
                    close,
                    cursor,
                    limits,
                    warnings,
                    quote_depth=quote_depth + 1,
                )
            )
            index = close + 1
        elif token.type in {"bullet_list_open", "ordered_list_open"}:
            close = _matching_close(
                tokens, index, end, token.type, f"{token.type.replace('_open', '_close')}"
            )
            blocks.extend(
                _parse_list(
                    tokens,
                    index + 1,
                    close,
                    cursor,
                    limits,
                    warnings,
                    quote_depth,
                    list_depth,
                    ordered=token.type == "ordered_list_open",
                )
            )
            index = close + 1
        elif token.type == "table_open":
            close = _matching_close(tokens, index, end, "table_open", "table_close")
            blocks.append(
                _parse_table(tokens, index + 1, close, cursor, limits, block_index)
            )
            index = close + 1
        else:
            # Structural closers and inline payloads are consumed by their
            # opening constructs; anything else at block level is skipped.
            index += 1
    return blocks


def _matching_close(
    tokens: list[Token], open_index: int, end: int, open_type: str, close_type: str
) -> int:
    depth = 0
    for index in range(open_index, end):
        token_type = tokens[index].type
        if token_type == open_type:
            depth += 1
        elif token_type == close_type:
            depth -= 1
            if depth == 0:
                return index
    raise UnsupportedMarkdown(f"unbalanced markdown structure: {open_type}")


def _parse_list(
    tokens: list[Token],
    start: int,
    end: int,
    cursor: _ParseCursor,
    limits: MarkdownLimits,
    warnings: list[ParseWarning],
    quote_depth: int,
    list_depth: int,
    *,
    ordered: bool,
) -> list[Block]:
    blocks: list[Block] = []
    item_depth = list_depth + 1
    if item_depth > limits.max_nesting_depth:
        raise MarkdownResourceLimit(f"list nesting exceeds {limits.max_nesting_depth}")
    index = start
    while index < end:
        token = tokens[index]
        if token.type != "list_item_open":
            index += 1
            continue
        close = _matching_close(tokens, index, end, "list_item_open", "list_item_close")
        kind = ListKind.ORDERED if ordered else ListKind.BULLET
        ordinal = int(token.info) if kind is ListKind.ORDERED and token.info.strip() else None
        item_inline, nested = _list_item_content(
            tokens, index + 1, close, cursor, limits, warnings, quote_depth, item_depth
        )
        if item_inline.text.strip():
            blocks.append(
                _text_block(
                    cursor,
                    style=TextBlockStyle.LIST_ITEM,
                    inline=item_inline,
                    limits=limits,
                    list_kind=kind,
                    list_depth=item_depth,
                    list_ordinal=ordinal,
                )
            )
        blocks.extend(nested)
        index = close + 1
    return blocks


def _list_item_content(
    tokens: list[Token],
    start: int,
    end: int,
    cursor: _ParseCursor,
    limits: MarkdownLimits,
    warnings: list[ParseWarning],
    quote_depth: int,
    item_depth: int,
) -> tuple[_Inline, list[Block]]:
    """First-pass inline text of a list item plus blocks nested inside it."""
    inline = _Inline()
    nested: list[Block] = []
    index = start
    while index < end:
        token = tokens[index]
        if (
            token.type == "paragraph_open"
            and index + 1 < end
            and tokens[index + 1].type == "inline"
        ):
            part = _inline(tokens[index + 1], limits, cursor.block_index + 1)
            if part.text.strip():
                if inline.text:
                    inline.text += " " + part.text
                    inline.runs.extend(part.runs)
                else:
                    inline.text = part.text
                    inline.runs = list(part.runs)
            index += 3
        elif token.type in {"bullet_list_open", "ordered_list_open", "blockquote_open"}:
            close_type = (
                token.type.replace("_open", "_close")
                if token.type != "blockquote_open"
                else "blockquote_close"
            )
            close = _matching_close(tokens, index, end, token.type, close_type)
            nested.extend(
                _parse_tokens(
                    tokens,
                    index,
                    close + 1,
                    cursor,
                    limits,
                    warnings,
                    quote_depth=quote_depth,
                    list_depth=item_depth,
                )
            )
            index = close + 1
        else:
            index += 1
    return inline, nested


def _parse_table(
    tokens: list[Token],
    start: int,
    end: int,
    cursor: _ParseCursor,
    limits: MarkdownLimits,
    block_index: int,
) -> TableBlock:
    alignments: list[TableAlignment] = []
    header: list[TableCell] = []
    rows: list[list[TableCell]] = []
    total_characters = 0
    cell_index = 0
    pad_counter = 0
    current_row: list[TableCell] | None = None
    index = start
    block_number = cursor.block_number + 1
    while index < end:
        token = tokens[index]
        if token.type in {"th_open", "td_open"}:
            close = _matching_close(tokens, index, end, token.type, f"{token.type[:2]}_close")
            inline = _inline(tokens[index + 1], limits, block_index)
            plain = inline.text.strip()
            if len(plain) > limits.max_table_cell_characters:
                raise MarkdownResourceLimit(
                    f"table cell exceeds {limits.max_table_cell_characters} characters"
                )
            total_characters += len(plain)
            if token.type == "td_open" and current_row is None:
                current_row = []
            cell = TableCell(
                cell_id=f"cell-{block_number}-{cell_index}",
                plain_text=plain,
                runs=tuple(
                    _clip_runs(inline.runs, _offset_of(inline.text, plain), len(plain))
                ),
            )
            cell_index += 1
            if token.type == "th_open":
                header.append(cell)
                alignments.append(_alignment(token))
            elif current_row is not None:
                current_row.append(cell)
            index = close + 1
        elif token.type == "tr_close":
            if current_row is not None:
                rows.append(current_row)
                current_row = None
            index += 1
        else:
            index += 1
    if current_row is not None:
        rows.append(current_row)
    # GFM pads missing cells with empty ones; we mirror that deterministically.
    for row in rows:
        pad_counter = _normalize_row_shape(row, len(header), block_number, pad_counter)
    if not header:
        raise UnsupportedMarkdown(f"table at block position {block_index} has no header")
    if len(header) > limits.max_table_columns:
        raise MarkdownResourceLimit(
            f"table has {len(header)} columns; limit is {limits.max_table_columns}"
        )
    if len(rows) > limits.max_table_rows:
        raise MarkdownResourceLimit(
            f"table has {len(rows)} rows; limit is {limits.max_table_rows}"
        )
    if total_characters > limits.max_table_total_characters:
        raise MarkdownResourceLimit(
            f"table visible text exceeds {limits.max_table_total_characters} characters"
        )
    if len(alignments) != len(header):
        alignments = alignments[: len(header)] or [TableAlignment.DEFAULT] * len(header)
    return TableBlock(
        block_id=cursor.next_block_id(),
        order=cursor.block_index,
        alignments=tuple(alignments[: len(header)]),
        header=tuple(header),
        rows=tuple(tuple(row) for row in rows),
    )


def _normalize_row_shape(
    row: list[TableCell], columns: int, block_number: int, pad_counter: int
) -> int:
    while len(row) < columns:
        row.append(
            TableCell(
                cell_id=f"cell-{block_number}-pad-{pad_counter}", plain_text=""
            )
        )
        pad_counter += 1
    del row[columns:]
    return pad_counter


def _alignment(token: Token) -> TableAlignment:
    style = (token.attrs or {}).get("style", "")
    mapping = {
        "text-align:left": TableAlignment.LEFT,
        "text-align:center": TableAlignment.CENTER,
        "text-align:right": TableAlignment.RIGHT,
    }
    return mapping.get(str(style), TableAlignment.DEFAULT)


def _offset_of(full_text: str, stripped: str) -> int:
    offset = full_text.find(stripped)
    return max(0, offset)


# -- inline parsing --------------------------------------------------------


def _inline(token: Token | None, limits: MarkdownLimits, block_index: int) -> _Inline:
    if token is None or not token.children:
        return _Inline()
    result = _Inline()
    styles: list[InlineRunKind] = []
    pending_href: str | None = None
    for child in token.children:
        if child.type == "text":
            normalized = _normalize_visible_text(child.content)
            result.text += normalized
            result.runs.append(
                InlineRun(_current_style(styles), normalized, pending_href)
            )
        elif child.type == "code_inline":
            result.text += child.content
            result.runs.append(InlineRun(InlineRunKind.CODE, child.content))
        elif child.type == "softbreak":
            result.text += " "
            result.runs.append(InlineRun(_current_style(styles), " "))
        elif child.type == "hardbreak":
            result.text += "\n"
            result.runs.append(InlineRun(InlineRunKind.HARD_BREAK, "\n"))
        elif child.type in {"em_open", "strong_open", "s_open", "link_open"}:
            kind = {
                "em_open": InlineRunKind.EMPHASIS,
                "strong_open": InlineRunKind.STRONG,
                "s_open": InlineRunKind.STRIKETHROUGH,
                "link_open": InlineRunKind.LINK,
            }[child.type]
            styles.append(kind)
            if child.type == "link_open":
                pending_href = str((child.attrs or {}).get("href", ""))
                if len(pending_href) > limits.max_link_href_characters:
                    raise MarkdownResourceLimit(
                        f"link target exceeds "
                        f"{limits.max_link_href_characters} characters"
                    )
        elif child.type in {"em_close", "strong_close", "s_close", "link_close"}:
            if styles:
                styles.pop()
            if child.type == "link_close":
                pending_href = None
        elif child.type == "image":
            alt = child.content or (child.children and "".join(
                nested.content for nested in child.children if nested.type == "text"
            )) or ""
            alt = _normalize_visible_text(alt) if alt else ""
            text = alt if alt.strip() else "[图片未包含]"
            src = str((child.attrs or {}).get("src", "")) or None
            result.text += text
            result.runs.append(InlineRun(InlineRunKind.IMAGE, text, src))
        elif child.type == "html_inline":
            raise UnsupportedMarkdown(
                f"inline raw HTML is not supported (block position {block_index})"
            )
    if len(result.runs) > limits.max_sentence_runs:
        raise MarkdownResourceLimit(
            f"inline runs exceed {limits.max_sentence_runs} (block position {block_index})"
        )
    _merge_adjacent_plain(result.runs)
    return result


def _current_style(styles: list[InlineRunKind]) -> InlineRunKind:
    if not styles:
        return InlineRunKind.PLAIN
    return max(styles, key=lambda kind: _STYLE_PRIORITY.get(kind, 0))


def _merge_adjacent_plain(runs: list[InlineRun]) -> None:
    merged: list[InlineRun] = []
    for run in runs:
        if (
            merged
            and merged[-1].kind == run.kind
            and merged[-1].kind not in {InlineRunKind.HARD_BREAK}
            and merged[-1].href == run.href
        ):
            merged[-1] = InlineRun(merged[-1].kind, merged[-1].text + run.text, merged[-1].href)
        else:
            merged.append(run)
    runs.clear()
    runs.extend(merged)


def _clip_runs(runs: list[InlineRun], offset: int, length: int) -> list[InlineRun]:
    """Clip runs to the [offset, offset+length) window of their concatenation."""
    clipped: list[InlineRun] = []
    position = 0
    for run in runs:
        run_end = position + len(run.text)
        start = max(position, offset)
        end = min(run_end, offset + length)
        if end > start:
            clipped.append(
                InlineRun(
                    run.kind,
                    run.text[start - position : end - position],
                    run.href,
                )
            )
        position = run_end
        if position >= offset + length:
            break
    return clipped


# -- sentence assembly -----------------------------------------------------


def _text_block(
    cursor: _ParseCursor,
    *,
    style: TextBlockStyle,
    inline: _Inline,
    limits: MarkdownLimits,
    heading_level: int | None = None,
    list_kind: ListKind | None = None,
    list_depth: int = 0,
    list_ordinal: int | None = None,
    quote_depth: int = 0,
) -> TextBlock:
    spans = _sentence_spans(inline.text)
    sentences = [
        Sentence(
            sentence_id=cursor.next_sentence_id(),
            order=order,
            text=inline.text[start:end],
            runs=tuple(_clip_runs(inline.runs, start, end - start)),
        )
        for order, (start, end) in enumerate(spans)
        if inline.text[start:end].strip()
    ]
    if len(sentences) > limits.max_block_sentences:
        raise MarkdownResourceLimit(
            f"a block has {len(sentences)} sentences; limit is "
            f"{limits.max_block_sentences}"
        )
    for sentence in sentences:
        if len(sentence.text) > limits.max_sentence_characters:
            raise MarkdownResourceLimit(
                f"sentence {sentence.sentence_id} exceeds "
                f"{limits.max_sentence_characters} characters"
            )
    return TextBlock(
        block_id=cursor.next_block_id(),
        order=cursor.block_index,
        style=style,
        sentences=tuple(sentences),
        heading_level=heading_level,
        list_kind=list_kind,
        list_depth=list_depth,
        list_ordinal=list_ordinal,
        quote_depth=quote_depth,
    )


def _sentence_spans(text: str) -> list[tuple[int, int]]:
    """Character spans of sentences in visible plain text (design §5.3).

    Abbreviation-aware terminator rules (mirrors the project's historical
    splitter policy) but returns offsets into the original string so runs can
    be sliced precisely.
    """
    spans: list[tuple[int, int]] = []
    start = 0
    index = 0
    length = len(text)
    while index < length:
        character = text[index]
        if character not in ".!?":
            index += 1
            continue
        if character == "." and period_is_nonterminal(text, index):
            index += 1
            continue
        end = index + 1
        while end < length and text[end] in ".!?":
            end += 1
        while end < length and text[end] in _CLOSING_PUNCTUATION:
            end += 1
        next_start = end
        while next_start < length and text[next_start].isspace():
            next_start += 1
        if next_start < length and text[next_start].islower():
            index = end
            continue
        if text[start:end].strip():
            spans.append(_stripped_span(text, start, end))
        start = next_start
        index = next_start
    if text[start:].strip():
        spans.append(_stripped_span(text, start, length))
    return spans


def _stripped_span(text: str, start: int, end: int) -> tuple[int, int]:
    while start < end and text[start].isspace():
        start += 1
    while end > start and text[end - 1].isspace():
        end -= 1
    return start, end


# -- limits & warnings ------------------------------------------------------


def enforce_document_limits(blocks: tuple[Block, ...], limits: MarkdownLimits) -> None:
    """Re-check the frozen resource limits over a typed document (§4.4).

    parse_markdown enforces the same values while walking tokens; this typed
    pass is the shared re-check for every other path that can produce or
    freeze a document (manual structure edits, approve/freeze, import) so the
    limits hold regardless of how the blocks were built.
    """
    if len(blocks) > limits.max_blocks:
        raise MarkdownResourceLimit(
            f"document has {len(blocks)} blocks; limit is {limits.max_blocks}"
        )
    total_code_bytes = 0
    for block in blocks:
        if isinstance(block, TextBlock):
            if len(block.sentences) > limits.max_block_sentences:
                raise MarkdownResourceLimit(
                    f"block {block.block_id} has {len(block.sentences)} "
                    f"sentences; limit is {limits.max_block_sentences}"
                )
            for sentence in block.sentences:
                if len(sentence.runs) > limits.max_sentence_runs:
                    raise MarkdownResourceLimit(
                        f"inline runs exceed {limits.max_sentence_runs} "
                        f"(sentence {sentence.sentence_id})"
                    )
                if len(sentence.text) > limits.max_sentence_characters:
                    raise MarkdownResourceLimit(
                        f"sentence {sentence.sentence_id} exceeds "
                        f"{limits.max_sentence_characters} characters"
                    )
                _check_run_hrefs(sentence.runs, limits)
            if block.list_depth > limits.max_nesting_depth:
                raise MarkdownResourceLimit(
                    f"list nesting exceeds {limits.max_nesting_depth}"
                )
            if block.quote_depth > limits.max_nesting_depth:
                raise MarkdownResourceLimit(
                    f"quote nesting exceeds {limits.max_nesting_depth}"
                )
        elif isinstance(block, TableBlock):
            if len(block.header) > limits.max_table_columns:
                raise MarkdownResourceLimit(
                    f"table has {len(block.header)} columns; "
                    f"limit is {limits.max_table_columns}"
                )
            if len(block.rows) > limits.max_table_rows:
                raise MarkdownResourceLimit(
                    f"table has {len(block.rows)} rows; limit is {limits.max_table_rows}"
                )
            total_characters = 0
            for cell in (
                *block.header,
                *(cell for row in block.rows for cell in row),
            ):
                if len(cell.runs) > limits.max_sentence_runs:
                    raise MarkdownResourceLimit(
                        f"table cell {cell.cell_id} inline runs exceed "
                        f"{limits.max_sentence_runs}"
                    )
                if len(cell.plain_text) > limits.max_table_cell_characters:
                    raise MarkdownResourceLimit(
                        f"table cell exceeds {limits.max_table_cell_characters} "
                        "characters"
                    )
                _check_run_hrefs(cell.runs, limits)
                total_characters += len(cell.plain_text)
            if total_characters > limits.max_table_total_characters:
                raise MarkdownResourceLimit(
                    f"table visible text exceeds "
                    f"{limits.max_table_total_characters} characters"
                )
        elif isinstance(block, CodeBlock):
            if block.language and len(block.language) > limits.max_language_characters:
                raise MarkdownResourceLimit(
                    f"code language exceeds {limits.max_language_characters} "
                    "characters"
                )
            block_bytes = len(block.code.encode("utf-8"))
            if block_bytes > limits.max_code_block_bytes:
                raise MarkdownResourceLimit(
                    f"code block exceeds {limits.max_code_block_bytes} bytes"
                )
            total_code_bytes += block_bytes
    if total_code_bytes > limits.max_total_code_bytes:
        raise MarkdownResourceLimit(
            f"total code bytes exceed {limits.max_total_code_bytes}"
        )


def _check_run_hrefs(runs: tuple[InlineRun, ...], limits: MarkdownLimits) -> None:
    for run in runs:
        if run.href and len(run.href) > limits.max_link_href_characters:
            raise MarkdownResourceLimit(
                f"link target exceeds {limits.max_link_href_characters} characters"
            )


def _code_block(
    cursor: _ParseCursor, code: str, language: str | None, limits: MarkdownLimits
) -> CodeBlock:
    if len(code.encode("utf-8")) > limits.max_code_block_bytes:
        raise MarkdownResourceLimit(
            f"code block exceeds {limits.max_code_block_bytes} bytes"
        )
    if language and len(language) > limits.max_language_characters:
        raise MarkdownResourceLimit(
            f"code language exceeds {limits.max_language_characters} characters"
        )
    return CodeBlock(
        block_id=cursor.next_block_id(),
        order=cursor.block_index,
        code=code,
        language=language,
    )


def _check_code_budget(blocks: list[Block], limits: MarkdownLimits) -> None:
    total = sum(
        len(block.code.encode("utf-8"))
        for block in blocks
        if isinstance(block, CodeBlock)
    )
    if total > limits.max_total_code_bytes:
        raise MarkdownResourceLimit(
            f"total code bytes exceed {limits.max_total_code_bytes}"
        )


def _unclosed_fence_warnings(canonical: str, block_count: int) -> list[ParseWarning]:
    """Detect an opening fence with no matching close (design §4.3).

    markdown-it tolerantly treats everything after an unclosed fence as code;
    we surface that as a warning so the structure page forces a human check
    before freezing.
    """
    warnings: list[ParseWarning] = []
    open_fence: tuple[str, str] | None = None
    for line in canonical.split("\n"):
        match = _FENCE_LINE.match(line)
        if match is None:
            continue
        marker = match.group(2)
        if open_fence is None:
            open_fence = (marker[0], marker)
        elif marker[0] == open_fence[0] and len(marker) >= len(open_fence[1]):
            open_fence = None
    if open_fence is not None:
        warnings.append(
            ParseWarning(
                code="unclosed_code_fence",
                message=(
                    "An unclosed code fence swallows the remaining text into a "
                    "code block; confirm the structure before freezing."
                ),
                block_index=block_count,
            )
        )
    return warnings


_NONTERMINAL_ABBREVIATIONS = {
    "dr",
    "e.g",
    "fig",
    "i.e",
    "jr",
    "mr",
    "mrs",
    "ms",
    "no",
    "prof",
    "sr",
    "st",
    "vs",
}
_CLOSING_PUNCTUATION = {'"', "'", "\u2019", "\u201d", ")", "]"}


def period_is_nonterminal(text: str, index: int) -> bool:
    """Whether the period at 'index' continues the current sentence."""
    if (
        index > 0
        and index + 1 < len(text)
        and text[index - 1].isdigit()
        and text[index + 1].isdigit()
    ):
        return True
    token_start = index
    while token_start > 0 and (text[token_start - 1].isalpha() or text[token_start - 1] == "."):
        token_start -= 1
    raw_token = text[token_start:index]
    token = raw_token.lower()
    if token in _NONTERMINAL_ABBREVIATIONS:
        return True
    if len(raw_token) == 1 and raw_token.isupper():
        return True
    dotted = f"{token}."
    return bool(re.fullmatch(r"(?:[a-z]\\.){2,}", dotted))
