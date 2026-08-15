from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class RevisionStatus(str, Enum):
    DRAFT = "draft"
    STRUCTURED = "structured"
    APPROVED = "approved"
    PUBLISHED = "published"


class BlockKind(str, Enum):
    """Wire-level block kinds shared by the Readpack v1.1 block union."""

    PARAGRAPH = "paragraph"
    LIST_ITEM = "list_item"
    QUOTE = "quote"
    HEADING = "heading"
    TABLE = "table"
    CODE = "code"
    DIVIDER = "divider"


class TextBlockStyle(str, Enum):
    """Internal presentation style of a narratable text block."""

    PARAGRAPH = "paragraph"
    LIST_ITEM = "list_item"
    QUOTE = "quote"
    HEADING = "heading"


class ListKind(str, Enum):
    BULLET = "bullet"
    ORDERED = "ordered"


class TableAlignment(str, Enum):
    DEFAULT = "default"
    LEFT = "left"
    CENTER = "center"
    RIGHT = "right"


class InlineRunKind(str, Enum):
    PLAIN = "plain"
    EMPHASIS = "emphasis"
    STRONG = "strong"
    STRIKETHROUGH = "strikethrough"
    CODE = "code"
    LINK = "link"
    IMAGE = "image"
    HARD_BREAK = "hard_break"


@dataclass(frozen=True)
class InlineRun:
    kind: InlineRunKind
    text: str
    href: str | None = None


@dataclass(frozen=True)
class Sentence:
    sentence_id: str
    order: int
    text: str
    runs: tuple[InlineRun, ...] = ()

    def __post_init__(self) -> None:
        # Invariant (design §5.2.5): the runs concatenate to exactly the visible
        # plain text. Enforced here so no constructor can produce an illegal
        # sentence regardless of the calling path. A sentence constructed without
        # explicit runs is an unformatted sentence and gets a single plain run
        # (design §9.2), so downstream consumers can always render from runs.
        if not self.runs:
            object.__setattr__(
                self, "runs", (InlineRun(InlineRunKind.PLAIN, self.text),)
            )
        visible = "".join(run.text for run in self.runs)
        if visible != self.text:
            raise ValueError(
                f"sentence {self.sentence_id!r} runs must concatenate to its text"
            )


@dataclass(frozen=True)
class TableCell:
    cell_id: str
    plain_text: str
    runs: tuple[InlineRun, ...] = ()

    def __post_init__(self) -> None:
        # Same invariant as Sentence (design §5.2.5): runs concatenate to
        # exactly the cell's visible plain text. A cell constructed without
        # explicit runs (manual structure edits, legacy rows) gets a single
        # plain run so packagers and renderers can always rely on runs.
        if not self.runs:
            object.__setattr__(
                self, "runs", (InlineRun(InlineRunKind.PLAIN, self.plain_text),)
            )
        visible = "".join(run.text for run in self.runs)
        if visible != self.plain_text:
            raise ValueError(
                f"table cell {self.cell_id!r} runs must concatenate to its text"
            )


@dataclass(frozen=True)
class ContentBlock:
    """Base of the typed block discriminated union (design §5.1)."""

    block_id: str
    order: int


@dataclass(frozen=True)
class TextBlock(ContentBlock):
    style: TextBlockStyle = TextBlockStyle.PARAGRAPH
    sentences: tuple[Sentence, ...] = ()
    heading_level: int | None = None
    list_kind: ListKind | None = None
    list_depth: int = 0
    list_ordinal: int | None = None
    quote_depth: int = 0

    @property
    def kind(self) -> BlockKind:
        return BlockKind(self.style.value)

    def __post_init__(self) -> None:
        if self.style is TextBlockStyle.HEADING:
            if self.heading_level is None or not 1 <= self.heading_level <= 6:
                raise ValueError(f"heading block {self.block_id!r} needs a 1-6 level")
        elif self.heading_level is not None:
            raise ValueError(f"non-heading block {self.block_id!r} must not carry a level")
        if self.style is TextBlockStyle.LIST_ITEM:
            if self.list_kind is None:
                raise ValueError(f"list block {self.block_id!r} needs a list kind")
            if self.list_depth < 0:
                raise ValueError(f"list block {self.block_id!r} has a negative depth")
        else:
            if self.list_kind is not None or self.list_depth or self.list_ordinal is not None:
                raise ValueError(f"non-list block {self.block_id!r} must not carry list fields")
        if self.style is TextBlockStyle.QUOTE:
            if self.quote_depth < 1:
                raise ValueError(f"quote block {self.block_id!r} needs a positive depth")
        elif self.quote_depth:
            raise ValueError(f"non-quote block {self.block_id!r} must not carry a quote depth")
        if not self.sentences:
            raise ValueError(f"text block {self.block_id!r} needs at least one sentence")


@dataclass(frozen=True)
class TableBlock(ContentBlock):
    alignments: tuple[TableAlignment, ...] = ()
    header: tuple[TableCell, ...] = ()
    rows: tuple[tuple[TableCell, ...], ...] = ()

    @property
    def kind(self) -> BlockKind:
        return BlockKind.TABLE

    def __post_init__(self) -> None:
        if not self.header:
            raise ValueError(f"table block {self.block_id!r} needs a header row")
        columns = len(self.header)
        if len(self.alignments) != columns:
            raise ValueError(
                f"table block {self.block_id!r} alignment count differs from columns"
            )
        for row in self.rows:
            if len(row) != columns:
                raise ValueError(f"table block {self.block_id!r} has a ragged row")


@dataclass(frozen=True)
class CodeBlock(ContentBlock):
    code: str = ""
    language: str | None = None

    @property
    def kind(self) -> BlockKind:
        return BlockKind.CODE

    def __post_init__(self) -> None:
        if not self.code:
            raise ValueError(f"code block {self.block_id!r} must not be empty")


@dataclass(frozen=True)
class DividerBlock(ContentBlock):
    @property
    def kind(self) -> BlockKind:
        return BlockKind.DIVIDER


# The block union consumed by every downstream module. A Block is exactly one
# of the four typed variants; `block.kind` derives the wire-level BlockKind.
Block = TextBlock | TableBlock | CodeBlock | DividerBlock


@dataclass(frozen=True)
class SourceAttribution:
    author: str | None
    display_name: str | None
    url: str | None
    license_name: str


@dataclass(frozen=True)
class ArticleRevision:
    article_id: str
    revision: int
    title: str
    # Raw user input exactly as submitted (source snapshot material).
    raw_text: str
    # Canonical markdown: only line endings unified to LF (design §8.1).
    normalized_text: str
    source: SourceAttribution
    source_sha256: str
    normalized_sha256: str
    structure_sha256: str
    status: RevisionStatus
    blocks: tuple[Block, ...]


@dataclass(frozen=True)
class NewArticle:
    title: str
    body: str
    author: str | None
    source_name: str | None
    source_url: str | None
    license_name: str


@dataclass(frozen=True)
class EditedSentence:
    text: str
    sentence_id: str | None = None


@dataclass(frozen=True)
class EditedTextBlock:
    style: TextBlockStyle
    sentences: tuple[EditedSentence, ...]
    block_id: str | None = None
    heading_level: int | None = None
    list_kind: ListKind | None = None
    list_depth: int = 0
    list_ordinal: int | None = None
    quote_depth: int = 0


@dataclass(frozen=True)
class EditedTableBlock:
    alignments: tuple[TableAlignment, ...]
    header: tuple[str, ...]
    rows: tuple[tuple[str, ...], ...]
    block_id: str | None = None


@dataclass(frozen=True)
class EditedCodeBlock:
    code: str
    language: str | None = None
    block_id: str | None = None


@dataclass(frozen=True)
class EditedDividerBlock:
    block_id: str | None = None


EditedBlock = EditedTextBlock | EditedTableBlock | EditedCodeBlock | EditedDividerBlock
