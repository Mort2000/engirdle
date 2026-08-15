"""Focused content-module tests for the markdown/unit pipeline (design §14.1).

Covers the GFM projection (headings, emphasis/link runs, sentence-boundary
emphasis, nested lists, quotes, GFM tables, byte-exact code blocks), parse
policy (pseudo-markdown inside code, unclosed fences, raw HTML), resource
limits, the versioned identifiers, ProcessingPlan routing, and the structure
edit lifecycle through ContentService.
"""

from __future__ import annotations

from dataclasses import replace

import pytest

from engirdle_pc.modules.content.application.service import ContentService
from engirdle_pc.modules.content.domain.entities import (
    ArticleRevision,
    CodeBlock,
    DividerBlock,
    EditedSentence,
    EditedTextBlock,
    InlineRun,
    InlineRunKind,
    ListKind,
    RevisionStatus,
    Sentence,
    SourceAttribution,
    TableAlignment,
    TableBlock,
    TextBlock,
    TextBlockStyle,
)
from engirdle_pc.modules.content.domain.errors import (
    ImmutableRevision,
    InvalidContent,
    MarkdownResourceLimit,
    NoNarratableContent,
    UnsupportedMarkdown,
)
from engirdle_pc.modules.content.domain.markdown import (
    DEFAULT_LIMITS,
    PARSE_VERSION,
    MarkdownLimits,
    parse_markdown,
)
from engirdle_pc.modules.content.domain.plan import (
    ProcessingPlan,
    SentencePauseKind,
)
from engirdle_pc.modules.content.domain.structure import (
    SEGMENTER_VERSION,
    materialize_edited_blocks,
    structure_sha256,
)
from engirdle_pc.modules.content.public import NewArticle
from engirdle_pc.shared.infrastructure.runtime import (
    SystemClock,
    UuidIdentifierGenerator,
)

# -- versioned identifiers ---------------------------------------------------


def test_parse_and_segmenter_versions_are_bumped_for_the_markdown_model() -> None:
    assert PARSE_VERSION == "engirdle-gfm@1"
    assert SEGMENTER_VERSION == "engirdle-segmenter@2"


# -- inline runs ------------------------------------------------------------


def test_heading_emphasis_and_link_runs_are_projected() -> None:
    parsed = parse_markdown(
        "# Big *important* title.\n\n"
        "See [the docs](https://example.com/a) and `pip install` soon."
    )
    heading, paragraph = parsed.blocks

    assert isinstance(heading, TextBlock)
    assert heading.style is TextBlockStyle.HEADING
    assert heading.heading_level == 1
    heading_runs = heading.sentences[0].runs
    assert [(run.kind, run.text) for run in heading_runs] == [
        (InlineRunKind.PLAIN, "Big "),
        (InlineRunKind.EMPHASIS, "important"),
        (InlineRunKind.PLAIN, " title."),
    ]

    assert isinstance(paragraph, TextBlock)
    runs = paragraph.sentences[0].runs
    kinds = [(run.kind, run.text) for run in runs]
    assert (InlineRunKind.LINK, "the docs") in kinds
    link_run = next(run for run in runs if run.kind is InlineRunKind.LINK)
    assert link_run.href == "https://example.com/a"
    code_run = next(run for run in runs if run.kind is InlineRunKind.CODE)
    assert code_run.text == "pip install"
    # Runs always concatenate to the visible sentence text.
    assert "".join(run.text for run in runs) == paragraph.sentences[0].text


def test_emphasis_crossing_a_sentence_boundary_keeps_style_on_both() -> None:
    parsed = parse_markdown("*One sentence. Two sentences.* Combined.")
    block = parsed.blocks[0]
    assert isinstance(block, TextBlock)
    first, second, third = block.sentences
    assert first.text == "One sentence."
    assert second.text == "Two sentences."
    assert third.text == "Combined."
    assert [(run.kind, run.text) for run in first.runs] == [
        (InlineRunKind.EMPHASIS, "One sentence.")
    ]
    assert [(run.kind, run.text) for run in second.runs] == [
        (InlineRunKind.EMPHASIS, "Two sentences.")
    ]
    assert [(run.kind, run.text) for run in third.runs] == [
        (InlineRunKind.PLAIN, "Combined.")
    ]
    assert "".join(run.text for run in first.runs + second.runs + third.runs) == (
        first.text + second.text + third.text
    )


def test_sentence_constructed_without_runs_gets_one_plain_run() -> None:
    sentence = Sentence(sentence_id="s", order=0, text="Plain words.")
    assert sentence.runs == (InlineRun(InlineRunKind.PLAIN, "Plain words."),)
    with pytest.raises(ValueError):
        Sentence(
            sentence_id="s",
            order=0,
            text="Visible text.",
            runs=(InlineRun(InlineRunKind.PLAIN, "different"),),
        )


# -- lists and quotes -------------------------------------------------------


def test_nested_lists_carry_depth_kind_and_ordinal() -> None:
    parsed = parse_markdown(
        "- top one.\n"
        "  1. nested first.\n"
        "  2. nested second.\n"
        "- top two.\n"
    )
    items = [block for block in parsed.blocks if isinstance(block, TextBlock)]
    assert all(block.style is TextBlockStyle.LIST_ITEM for block in items)
    by_text = {block.sentences[0].text: block for block in items}
    assert by_text["top one."].list_depth == 1
    assert by_text["top one."].list_ordinal is None
    assert by_text["nested first."].list_depth == 2
    assert by_text["nested first."].list_ordinal == 1
    assert by_text["nested second."].list_ordinal == 2
    assert by_text["top two."].list_depth == 1
    # Orders are contiguous and document-ordered after allocation.
    assert [block.order for block in items] == [0, 1, 2, 3]
    assert [block.sentences[0].text for block in items] == [
        "top one.",
        "nested first.",
        "nested second.",
        "top two.",
    ]


def test_quote_blocks_carry_depth() -> None:
    parsed = parse_markdown("> > Doubly quoted.\n\n> Single.\n")
    blocks = [block for block in parsed.blocks if isinstance(block, TextBlock)]
    assert all(block.style is TextBlockStyle.QUOTE for block in blocks)
    assert [block.quote_depth for block in blocks] == [2, 1]


# -- tables -----------------------------------------------------------------


def test_gfm_table_header_rows_alignment_and_cell_ids() -> None:
    parsed = parse_markdown(
        "| Left | Mid | Right |\n| :--- | :---: | ---: |\n| a | b | c |\n| x |\n"
    )
    assert len(parsed.blocks) == 1
    table = parsed.blocks[0]
    assert isinstance(table, TableBlock)
    assert [alignment for alignment in table.alignments] == [
        TableAlignment.LEFT,
        TableAlignment.CENTER,
        TableAlignment.RIGHT,
    ]
    assert [cell.plain_text for cell in table.header] == ["Left", "Mid", "Right"]
    assert [[cell.plain_text for cell in row] for row in table.rows] == [
        ["a", "b", "c"],
        # GFM pads a ragged row with empty cells.
        ["x", "", ""],
    ]
    cell_ids = [cell.cell_id for cell in table.header]
    cell_ids += [cell.cell_id for row in table.rows for cell in row]
    assert len(cell_ids) == len(set(cell_ids))
    assert all(cell_id.startswith("cell-1-") for cell_id in cell_ids)


# -- code blocks ------------------------------------------------------------


def test_fenced_and_indented_code_are_preserved_byte_for_byte() -> None:
    fence_body = "def f():\n    return '  spaced  '\n\n\nx = 1\n"
    indented_body = "indented line\n        deeper\n    tail\n"
    parsed = parse_markdown(
        "```python\n" + fence_body + "```\n\n"
        "Intro.\n\n    " + indented_body.replace("\n", "\n    ")
    )
    fenced = parsed.blocks[0]
    paragraph = parsed.blocks[1]
    indented = parsed.blocks[2]
    assert isinstance(fenced, CodeBlock)
    assert fenced.code == fence_body  # exact bytes: indentation + blank lines
    assert fenced.language == "python"
    assert isinstance(paragraph, TextBlock)
    assert isinstance(indented, CodeBlock)
    assert indented.code == indented_body
    assert indented.language is None


def test_pseudo_markdown_inside_code_produces_no_headings_tables_or_sentences() -> None:
    inner = (
        "# Not a heading\n"
        "| a | b |\n| - | - |\n| 1 | 2 |\n"
        "*Not emphasis.* A sentence. Another one!\n"
    )
    parsed = parse_markdown("```yaml\n" + inner + "```\n")
    assert len(parsed.blocks) == 1
    code_block = parsed.blocks[0]
    assert isinstance(code_block, CodeBlock)
    assert code_block.code == inner
    assert code_block.language == "yaml"
    assert parsed.warnings == ()

    revision = ArticleRevision(
        article_id="a",
        revision=1,
        title="Code only",
        raw_text="",
        normalized_text="",
        source=SourceAttribution(None, None, None, "unknown"),
        source_sha256="",
        normalized_sha256="",
        structure_sha256="",
        status=RevisionStatus.STRUCTURED,
        blocks=parsed.blocks,
    )
    plan = ProcessingPlan.derive(revision)
    assert plan.translation.units == ()
    assert plan.narration.units == ()


# -- parse policy and limits ------------------------------------------------


def test_unclosed_code_fence_yields_a_warning_but_still_parses() -> None:
    parsed = parse_markdown("Opening line.\n\n```python\ncode without end")
    assert [warning.code for warning in parsed.warnings] == ["unclosed_code_fence"]
    kinds = [block.kind.value for block in parsed.blocks]
    assert kinds == ["paragraph", "code"]


def test_raw_html_raises_unsupported_markdown() -> None:
    with pytest.raises(UnsupportedMarkdown):
        parse_markdown("<div>blocked</div>\n\nText.")
    with pytest.raises(UnsupportedMarkdown):
        parse_markdown("Inline <b>bold</b> html.")
    with pytest.raises(UnsupportedMarkdown):
        parse_markdown("   \n\n")


def test_five_level_nesting_exceeds_the_resource_limit() -> None:
    with pytest.raises(MarkdownResourceLimit):
        parse_markdown("> > > > > Far too deep.")
    deep_list = "- a\n"
    for level in range(2, 6):
        deep_list += "  " * (level - 1) + f"- item-{level}.\n"
    with pytest.raises(MarkdownResourceLimit):
        parse_markdown(deep_list)


def test_table_column_limit_can_be_tightened_via_markdown_limits() -> None:
    markdown = "| a | b | c |\n| - | - | - |\n| 1 | 2 | 3 |\n"
    assert len(parse_markdown(markdown).blocks) == 1
    tightened = MarkdownLimits(max_table_columns=2)
    with pytest.raises(MarkdownResourceLimit):
        parse_markdown(markdown, tightened)


def test_canonical_markdown_only_unifies_line_endings() -> None:
    parsed = parse_markdown("A\r\n\rB.\r\nC.")
    assert parsed.canonical_markdown == "A\n\nB.\nC."


# -- processing plan routing ------------------------------------------------


def _revision(blocks: tuple) -> ArticleRevision:
    return ArticleRevision(
        article_id="art-plan",
        revision=3,
        title="Plan",
        raw_text="",
        normalized_text="",
        source=SourceAttribution(None, None, None, "unknown"),
        source_sha256="",
        normalized_sha256="",
        structure_sha256="",
        status=RevisionStatus.STRUCTURED,
        blocks=blocks,
    )


def test_plan_routes_units_and_pause_kinds() -> None:
    parsed = parse_markdown(
        "# Head.\n\n"
        "One. Two.\n\n"
        "| a | b |\n| - | - |\n| 1 | 2 |\n\n"
        "```js\ncode();\n```\n\n"
        "---\n\n"
        "Last words."
    )
    plan = ProcessingPlan.derive(_revision(parsed.blocks))

    unit_kinds = [(type(unit).__name__, unit.unit_id) for unit in plan.translation.units]
    assert [kind for kind, _ in unit_kinds] == [
        "SentenceBatchUnit",
        "SentenceBatchUnit",
        "TableUnit",
        "SentenceBatchUnit",
    ]
    table_block_id = unit_kinds[2][1]
    assert plan.translation.table_units[0].cell_ids

    narrations = plan.narration.units
    assert [unit.text for unit in narrations] == [
        "Head.",
        "One.",
        "Two.",
        "Last words.",
    ]
    assert [unit.pause_kind for unit in narrations] == [
        SentencePauseKind.BLOCK_END,
        SentencePauseKind.WITHIN_BLOCK,
        SentencePauseKind.BLOCK_END,
        SentencePauseKind.ARTICLE_END,
    ]
    assert all(unit.source_block_id != table_block_id for unit in narrations)
    # Render keeps every block for packaging, including code and dividers.
    assert [type(block).__name__ for block in plan.render.blocks] == [
        "TextBlock",
        "TextBlock",
        "TableBlock",
        "CodeBlock",
        "DividerBlock",
        "TextBlock",
    ]


def test_structure_hash_is_union_aware() -> None:
    heading_a = TextBlock(
        block_id="block-1",
        order=0,
        style=TextBlockStyle.HEADING,
        heading_level=1,
        sentences=(Sentence("s1", 0, "Title."),),
    )
    heading_b = TextBlock(
        block_id="block-1",
        order=0,
        style=TextBlockStyle.HEADING,
        heading_level=2,
        sentences=(Sentence("s1", 0, "Title."),),
    )
    code_a = CodeBlock(block_id="block-1", order=0, code="a")
    code_b = CodeBlock(block_id="block-1", order=0, code="b")
    divider = DividerBlock(block_id="block-1", order=0)
    assert structure_sha256((heading_a,)) != structure_sha256((heading_b,))
    assert structure_sha256((code_a,)) != structure_sha256((code_b,))
    hashes = {
        structure_sha256((heading_a,)),
        structure_sha256((code_a,)),
        structure_sha256((divider,)),
    }
    assert len(hashes) == 3


# -- structure edits --------------------------------------------------------


def test_materialize_edited_blocks_allocates_unique_ids() -> None:
    blocks = materialize_edited_blocks(
        (
            EditedTextBlock(
                block_id="block-9",
                style=TextBlockStyle.PARAGRAPH,
                sentences=(EditedSentence(sentence_id="sentence-9", text="Kept."),),
            ),
            EditedTextBlock(
                style=TextBlockStyle.PARAGRAPH,
                sentences=(EditedSentence(text="New sentence."),),
            ),
        )
    )
    block_ids = [block.block_id for block in blocks]
    assert len(block_ids) == len(set(block_ids))
    assert blocks[0].block_id == "block-9"
    # Auto allocation never collides with a provided id; the counter only
    # moves forward, so the second block lands on the next free number.
    assert blocks[1].block_id == "block-2"
    sentence_ids = [
        sentence.sentence_id for block in blocks for sentence in block.sentences
    ]
    assert sentence_ids == ["sentence-9", "sentence-2"]

    with pytest.raises(InvalidContent):
        materialize_edited_blocks(
            (
                EditedTextBlock(
                    block_id="dup",
                    style=TextBlockStyle.PARAGRAPH,
                    sentences=(EditedSentence(text="One."),),
                ),
                EditedTextBlock(
                    block_id="dup",
                    style=TextBlockStyle.PARAGRAPH,
                    sentences=(EditedSentence(text="Two."),),
                ),
            )
        )
    with pytest.raises(InvalidContent):
        materialize_edited_blocks(
            (EditedTextBlock(style=TextBlockStyle.PARAGRAPH, sentences=()),)
        )
    with pytest.raises(InvalidContent):
        materialize_edited_blocks(())


class InMemoryContentStore:
    """Minimal ContentStore double for the service-lifecycle tests."""

    def __init__(self) -> None:
        self.revisions: dict[tuple[str, int], ArticleRevision] = {}

    def insert(self, revision: ArticleRevision, created_at: str) -> None:
        self.revisions[(revision.article_id, revision.revision)] = revision

    def insert_revision(self, revision: ArticleRevision, created_at: str) -> None:
        self.revisions[(revision.article_id, revision.revision)] = revision

    def latest_revision(self, article_id: str) -> ArticleRevision:
        matching = [
            (number, revision)
            for (article, number), revision in self.revisions.items()
            if article == article_id
        ]
        if not matching:
            raise InvalidContent(f"article {article_id} not found")
        return max(matching, key=lambda item: item[0])[1]

    def replace_structure(self, revision: ArticleRevision) -> None:
        self.revisions[(revision.article_id, revision.revision)] = revision

    def approve(self, article_id: str, revision: int, approved_at: str) -> None:
        current = self.revisions[(article_id, revision)]
        self.revisions[(article_id, revision)] = current.__class__(
            **{**current.__dict__, "status": RevisionStatus.APPROVED}
        )

    def mark_published(self, article_id: str, revision: int, published_at: str) -> None:
        current = self.revisions[(article_id, revision)]
        self.revisions[(article_id, revision)] = current.__class__(
            **{**current.__dict__, "status": RevisionStatus.PUBLISHED}
        )

    def get(self, article_id: str, revision: int) -> ArticleRevision:
        return self.revisions[(article_id, revision)]

    def list_latest(self) -> tuple[ArticleRevision, ...]:
        return tuple(self.revisions.values())

    def delete_article(self, article_id: str) -> None:
        for key in [key for key in self.revisions if key[0] == article_id]:
            del self.revisions[key]


class NullSnapshotStore:
    def save(self, revision: ArticleRevision) -> None:
        return None

    def discard(self, article_id: str, revision: int) -> None:
        return None


def _service() -> tuple[ContentService, InMemoryContentStore]:
    store = InMemoryContentStore()
    return (
        ContentService(store, NullSnapshotStore(), SystemClock(), UuidIdentifierGenerator()),
        store,
    )


def _new_article(body: str) -> NewArticle:
    return NewArticle(
        title="Service flow",
        body=body,
        author=None,
        source_name=None,
        source_url=None,
        license_name="unknown",
    )


def test_edit_structure_keeps_ids_unique_and_changes_the_hash() -> None:
    service, store = _service()
    revision = service.create(_new_article("One. Two.\n\n- An item."))
    original_hash = revision.structure_sha256

    edited = service.edit_structure(
        revision.article_id,
        revision.revision,
        (
            EditedTextBlock(
                block_id=revision.blocks[1].block_id,
                style=TextBlockStyle.LIST_ITEM,
                list_kind=ListKind.BULLET,
                sentences=(
                    EditedSentence(
                        sentence_id=revision.blocks[1].sentences[0].sentence_id,
                        text="An edited item.",
                    ),
                ),
            ),
            EditedTextBlock(
                style=TextBlockStyle.PARAGRAPH,
                sentences=(EditedSentence(text="A fresh sentence."),),
            ),
        ),
    )
    assert edited.structure_sha256 != original_hash
    assert edited.status is RevisionStatus.STRUCTURED
    stored = store.get(revision.article_id, revision.revision)
    assert stored.structure_sha256 == edited.structure_sha256
    block_ids = [block.block_id for block in edited.blocks]
    sentence_ids = [
        sentence.sentence_id for block in edited.blocks for sentence in block.sentences
    ]
    assert len(block_ids) == len(set(block_ids))
    assert len(sentence_ids) == len(set(sentence_ids))

    with pytest.raises(InvalidContent):
        service.edit_structure(
            revision.article_id,
            revision.revision,
            (
                EditedTextBlock(
                    block_id="block-x",
                    style=TextBlockStyle.PARAGRAPH,
                    sentences=(EditedSentence(text="One."),),
                ),
                EditedTextBlock(
                    block_id="block-x",
                    style=TextBlockStyle.PARAGRAPH,
                    sentences=(EditedSentence(text="Two."),),
                ),
            ),
        )


def test_frozen_revision_cannot_be_edited_and_code_only_cannot_be_approved() -> None:
    service, _store = _service()
    code_only = service.create(_new_article("```python\nx = 1\n```"))
    with pytest.raises(NoNarratableContent):
        service.approve(code_only.article_id, code_only.revision)

    revision = service.create(_new_article("Narratable sentence."))
    service.approve(revision.article_id, revision.revision)
    with pytest.raises(ImmutableRevision):
        service.edit_structure(
            revision.article_id,
            revision.revision,
            (
                EditedTextBlock(
                    style=TextBlockStyle.PARAGRAPH,
                    sentences=(EditedSentence(text="Too late."),),
                ),
            ),
        )


# -- plain-text legacy equivalence -----------------------------------------


def test_plain_text_input_maps_to_legacy_block_semantics() -> None:
    parsed = parse_markdown(
        "First paragraph line.\n\n"
        "Second paragraph. More text.\n\n"
        "- one item.\n- another item.\n\n"
        "> a quoted line.\n"
    )
    blocks = parsed.blocks
    assert [block.kind.value for block in blocks] == [
        "paragraph",
        "paragraph",
        "list_item",
        "list_item",
        "quote",
    ]
    first, second = blocks[0], blocks[1]
    assert isinstance(first, TextBlock) and isinstance(second, TextBlock)
    assert [sentence.text for sentence in first.sentences] == ["First paragraph line."]
    assert [sentence.text for sentence in second.sentences] == [
        "Second paragraph.",
        "More text.",
    ]
    for block in blocks:
        assert isinstance(block, TextBlock)
        for sentence in block.sentences:
            assert all(run.kind is InlineRunKind.PLAIN for run in sentence.runs)


# -- wire-cap parity with the Readpack schema (design §4.4) ----------------


def test_wire_caps_reject_oversized_sentence_language_and_link() -> None:
    from engirdle_pc.modules.content.domain.errors import MarkdownResourceLimit

    # Sentence text: 20,000 visible characters pass, 20,001 reject.
    parse_markdown("Word " + "a" * 19_994 + ".")
    with pytest.raises(MarkdownResourceLimit, match="sentence"):
        parse_markdown("Word " + "a" * 19_995 + ".")

    # Fence language: 64 characters pass, 65 reject.
    parse_markdown(f"```{'x' * 64}\ncode\n```")
    with pytest.raises(MarkdownResourceLimit, match="language"):
        parse_markdown(f"```{'x' * 65}\ncode\n```")

    # Link target: 2,048 characters pass, 2,049 reject ("https://e.x/" = 12).
    parse_markdown(f"[label](https://e.x/{'a' * 2_036})")
    with pytest.raises(MarkdownResourceLimit, match="link target"):
        parse_markdown(f"[label](https://e.x/{'a' * 2_037})")


def test_wire_caps_reject_blocks_with_too_many_sentences() -> None:
    from engirdle_pc.modules.content.domain.errors import MarkdownResourceLimit

    body = " ".join(f"Sentence {i}." for i in range(10_001))
    with pytest.raises(MarkdownResourceLimit, match="sentences"):
        parse_markdown(body)


def test_enforce_document_limits_rejects_edited_wire_cap_violations() -> None:
    """The typed re-check covers structures the parser never saw (§11.2)."""
    from engirdle_pc.modules.content.domain.errors import MarkdownResourceLimit
    from engirdle_pc.modules.content.domain.markdown import enforce_document_limits

    base = parse_markdown("One sentence. Two sentences.")
    block = base.blocks[0]
    assert isinstance(block, TextBlock)
    long_block = replace(
        block,
        sentences=block.sentences * 5_001,
    )
    with pytest.raises(MarkdownResourceLimit, match="sentences"):
        enforce_document_limits((long_block,), DEFAULT_LIMITS)

    long_sentence = replace(
        block,
        sentences=(Sentence("s-x", 0, "x" * 20_001),),
    )
    with pytest.raises(MarkdownResourceLimit, match="sentence s-x"):
        enforce_document_limits((long_sentence,), DEFAULT_LIMITS)

    long_language = CodeBlock("block-c", 0, code="x", language="l" * 65)
    with pytest.raises(MarkdownResourceLimit, match="language"):
        enforce_document_limits((long_language,), DEFAULT_LIMITS)
