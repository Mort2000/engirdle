"""Processing projections derived once from a frozen document (design §6).

`ProcessingPlan` is the single source of processing truth: the worker,
adapters, packager and reviewers all consume these typed projections instead
of re-deciding block-type policy. Code blocks and dividers appear in NONE of
the translation/narration projections — that exclusion is what guarantees
code bodies never reach an LLM or TTS request.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from engirdle_pc.modules.content.domain.entities import (
    ArticleRevision,
    Block,
    CodeBlock,
    DividerBlock,
    InlineRun,
    Sentence,
    TableAlignment,
    TableBlock,
    TableCell,
    TextBlock,
)


class SentencePauseKind(str, Enum):
    WITHIN_BLOCK = "within_block"
    BLOCK_END = "block_end"
    ARTICLE_END = "article_end"


@dataclass(frozen=True)
class ContextText:
    """One translatable visible text with its inline runs (§8.3)."""

    text: str
    runs: tuple[InlineRun, ...] = ()


class ContextItemKind(str, Enum):
    SENTENCES = "sentences"
    TABLE = "table"
    OMITTED_CODE = "omitted_code"


@dataclass(frozen=True)
class ContextItem:
    """Code-free context entry derived from one block (§8.3).

    SENTENCES carries a text block's sentences; TABLE carries one table's
    cells (header first, then rows in reading order); OMITTED_CODE is a
    content-free marker. Dividers are excluded entirely. This projection is
    the ONLY shape downstream modules may consume to build LLM context, so
    block-type policy stays decided here and code bodies can never leak.
    """

    kind: ContextItemKind
    sentences: tuple[ContextText, ...] = ()
    cells: tuple[ContextText, ...] = ()
    columns: int = 0


@dataclass(frozen=True)
class SentenceBatchUnit:
    """One text block's visible sentences sent as one ordered batch (§8.2)."""

    block_id: str
    sentences: tuple[Sentence, ...]

    @property
    def unit_id(self) -> str:
        return self.block_id

    @property
    def sentence_ids(self) -> tuple[str, ...]:
        return tuple(sentence.sentence_id for sentence in self.sentences)


@dataclass(frozen=True)
class TablePlanCell:
    cell_id: str
    plain_text: str
    runs: tuple[InlineRun, ...] = ()


@dataclass(frozen=True)
class TableUnit:
    """One table sent whole as a single LLM request (§8.2). Never narrated."""

    block_id: str
    alignments: tuple[TableAlignment, ...]
    header: tuple[TablePlanCell, ...]
    rows: tuple[tuple[TablePlanCell, ...], ...]

    @property
    def unit_id(self) -> str:
        return self.block_id

    @property
    def cell_ids(self) -> tuple[str, ...]:
        return tuple(cell.cell_id for cell in self.header) + tuple(
            cell.cell_id for row in self.rows for cell in row
        )


TranslationUnit = SentenceBatchUnit | TableUnit


@dataclass(frozen=True)
class NarrationUnit:
    """One narratable sentence in article order (§8.6).

    Speech adapters can only be handed this type: tables, code and dividers
    have no construction path to it.
    """

    sentence_id: str
    text: str
    source_block_id: str
    order: int
    pause_kind: SentencePauseKind


@dataclass(frozen=True)
class TranslationPlan:
    units: tuple[TranslationUnit, ...]

    @property
    def sentence_units(self) -> tuple[SentenceBatchUnit, ...]:
        return tuple(
            unit for unit in self.units if isinstance(unit, SentenceBatchUnit)
        )

    @property
    def table_units(self) -> tuple[TableUnit, ...]:
        return tuple(unit for unit in self.units if isinstance(unit, TableUnit))

    @property
    def unit_ids(self) -> tuple[str, ...]:
        return tuple(unit.unit_id for unit in self.units)


@dataclass(frozen=True)
class NarrationPlan:
    units: tuple[NarrationUnit, ...]

    @property
    def sentence_ids(self) -> tuple[str, ...]:
        return tuple(unit.sentence_id for unit in self.units)


@dataclass(frozen=True)
class RenderDocument:
    """All blocks and inline structure for packaging and mobile rendering."""

    article_id: str
    revision: int
    title: str
    blocks: tuple[Block, ...]


@dataclass(frozen=True)
class ProcessingPlan:
    translation: TranslationPlan
    narration: NarrationPlan
    render: RenderDocument

    @property
    def translation_context(self) -> tuple[ContextItem, ...]:
        """Typed code-free context projection (design §8.3).

        Same block-type policy as the translation plan — code blocks appear
        only as content-free markers and dividers are skipped — so consumers
        never re-decide policy over the raw render document.
        """
        items: list[ContextItem] = []
        for block in self.render.blocks:
            if isinstance(block, TextBlock):
                items.append(
                    ContextItem(
                        kind=ContextItemKind.SENTENCES,
                        sentences=tuple(
                            ContextText(text=sentence.text, runs=sentence.runs)
                            for sentence in block.sentences
                        ),
                    )
                )
            elif isinstance(block, TableBlock):
                items.append(
                    ContextItem(
                        kind=ContextItemKind.TABLE,
                        columns=len(block.header),
                        cells=tuple(
                            ContextText(text=cell.plain_text, runs=cell.runs)
                            for cell in (
                                *block.header,
                                *(cell for row in block.rows for cell in row),
                            )
                        ),
                    )
                )
            elif isinstance(block, CodeBlock):
                items.append(ContextItem(kind=ContextItemKind.OMITTED_CODE))
        return tuple(items)

    @classmethod
    def derive(cls, revision: ArticleRevision) -> ProcessingPlan:
        translation_units: list[TranslationUnit] = []
        narration_units: list[NarrationUnit] = []
        narration_order = 0
        blocks = revision.blocks
        for position, block in enumerate(blocks):
            if isinstance(block, TextBlock):
                if block.sentences:
                    translation_units.append(
                        SentenceBatchUnit(
                            block_id=block.block_id, sentences=block.sentences
                        )
                    )
                for sentence_index, sentence in enumerate(block.sentences):
                    last_in_block = sentence_index == len(block.sentences) - 1
                    last_in_article = last_in_block and position == len(blocks) - 1
                    pause_kind = (
                        SentencePauseKind.ARTICLE_END
                        if last_in_article
                        else SentencePauseKind.BLOCK_END
                        if last_in_block
                        else SentencePauseKind.WITHIN_BLOCK
                    )
                    narration_units.append(
                        NarrationUnit(
                            sentence_id=sentence.sentence_id,
                            text=sentence.text,
                            source_block_id=block.block_id,
                            order=narration_order,
                            pause_kind=pause_kind,
                        )
                    )
                    narration_order += 1
            elif isinstance(block, TableBlock):
                translation_units.append(_table_unit(block))
            elif isinstance(block, (CodeBlock, DividerBlock)):
                continue  # excluded from every LLM/TTS path by construction
        return cls(
            translation=TranslationPlan(units=tuple(translation_units)),
            narration=NarrationPlan(units=tuple(narration_units)),
            render=RenderDocument(
                article_id=revision.article_id,
                revision=revision.revision,
                title=revision.title,
                blocks=blocks,
            ),
        )


def _table_unit(block: TableBlock) -> TableUnit:
    def cell(source: TableCell) -> TablePlanCell:
        return TablePlanCell(
            cell_id=source.cell_id,
            plain_text=source.plain_text,
            runs=source.runs,
        )

    return TableUnit(
        block_id=block.block_id,
        alignments=block.alignments,
        header=tuple(cell(item) for item in block.header),
        rows=tuple(tuple(cell(item) for item in row) for row in block.rows),
    )
