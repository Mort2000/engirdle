"""Typed translation units and protected-token handling (design §8.2/§8.3).

The translation module consumes the content module's ProcessingPlan
projections. Two unit kinds exist:

- sentence batch — one text block's visible sentences, sent as one bare JSON
  array (with protected tokens in place of inline code / link URIs);
- table — one whole table, sent as one structured JSON object, never split
  per cell.

Protected tokens (design §8.2): inline code literals and link URIs never
enter an LLM request. Protection is occurrence-based: every protected run
inline occurrence is replaced, in wire order, by its own stable placeholder;
the mapping lives only in the PC process and the persistent checkpoint, and
the literal is restored after the model returns. A response that drops or
alters a placeholder fails with a protected-token mismatch. A link whose
display text is not the URI itself contributes no token — the URI never
appears in the wire text, so there is nothing to protect — while a link whose
visible text IS the URI (``[https://…](https://…)``) is protected so the URL
survives translation untouched.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum

from engirdle_pc.modules.content.domain.entities import InlineRun, InlineRunKind
from engirdle_pc.modules.content.domain.plan import (
    SentenceBatchUnit,
    TableUnit,
)

_PLACEHOLDER = "\u2030"  # per-mille sign: rare in prose, JSON-safe
# Canonical placeholder shape: STRICT ASCII digits between two sentinels.
# Python's \d would also match non-ASCII digits (Arabic-Indic zero), and
# int() would then normalize them onto a real index — the regex must stay
# ASCII-only and
# consumers must compare the FULL placeholder string, never a parsed index.
_PLACEHOLDER_PATTERN = re.compile(rf"{_PLACEHOLDER}([0-9]+){_PLACEHOLDER}")


class UnitKind(str, Enum):
    SENTENCE = "sentence"
    TABLE = "table"


@dataclass(frozen=True)
class ProtectedToken:
    index: int
    literal: str
    # The wire slot (sentence / table cell position) the token came from.
    # Verification is slot-aware: the placeholder must survive exactly once
    # and IN ITS OWN slot, so a model swapping two placeholders between
    # sentences/cells is rejected instead of silently binding the wrong
    # literal to the wrong slot.
    slot: int = 0

    @property
    def placeholder(self) -> str:
        return f"{_PLACEHOLDER}{self.index}{_PLACEHOLDER}"


@dataclass(frozen=True)
class ProtectedTokenMap:
    tokens: tuple[ProtectedToken, ...] = ()

    def restore(self, text: str) -> str:
        """Restore placeholders in ONE pass.

        A sequential str.replace chain would cascade: if token 0's literal
        itself contains token 1's placeholder pattern, restoring token 0
        would expose it to token 1's replacement. A single regex scan maps
        each FULL placeholder string to its literal exactly once and never
        rescans the substituted text. Matching is by the complete canonical
        spelling — no index parsing — so leading-zero or Unicode-digit
        lookalikes can never normalize onto a real token.
        """
        by_placeholder = {token.placeholder: token for token in self.tokens}

        def _sub(match: re.Match[str]) -> str:
            token = by_placeholder.get(match.group(0))
            return token.literal if token is not None else match.group(0)

        return _PLACEHOLDER_PATTERN.sub(_sub, text)

    def placeholders(self) -> tuple[str, ...]:
        return tuple(token.placeholder for token in self.tokens)


def protect_run_lists(
    run_lists: tuple[tuple[InlineRun, ...], ...]
) -> tuple[tuple[str, ...], ProtectedTokenMap]:
    """Build the protected wire texts from inline runs, occurrence-based.

    Walks each run list in order; every protected run (inline code, or a link
    whose visible text is its own URI) becomes its own indexed placeholder
    carrying its slot (the run-list position), and every other run contributes
    its visible text as-is. Returns the wire texts parallel to 'run_lists'
    plus the token map. Deterministic: the same document always produces the
    same wire and map.
    """
    texts: list[str] = []
    tokens: list[ProtectedToken] = []
    for slot, runs in enumerate(run_lists):
        parts: list[str] = []
        for run in runs:
            if _is_protected_run(run):
                token = ProtectedToken(
                    index=len(tokens), literal=run.text, slot=slot
                )
                tokens.append(token)
                parts.append(token.placeholder)
            else:
                parts.append(run.text)
        texts.append("".join(parts))
    return tuple(texts), ProtectedTokenMap(tokens=tuple(tokens))


def _is_protected_run(run: InlineRun) -> bool:
    if run.kind is InlineRunKind.CODE:
        return bool(run.text)
    if run.kind is InlineRunKind.LINK:
        # Autolinks (display text == URI): the URL must survive translation.
        # Ordinary links translate their display text; the href never enters
        # the wire, so no token is needed for it.
        return bool(run.href) and run.text.strip() == (run.href or "").strip()
    return False


def unit_run_lists(
    unit: SentenceBatchUnit | TableUnit,
) -> tuple[tuple[InlineRun, ...], ...]:
    """The unit's run lists in wire order (sentences; header then row cells)."""
    if isinstance(unit, SentenceBatchUnit):
        return tuple(sentence.runs for sentence in unit.sentences)
    return tuple(
        cell.runs
        for cell in (*unit.header, *(cell for row in unit.rows for cell in row))
    )


@dataclass(frozen=True)
class SentenceTranslation:
    sentence_id: str
    text_zh: str


@dataclass(frozen=True)
class SentenceUnitTranslation:
    block_id: str
    translations: tuple[SentenceTranslation, ...]


@dataclass(frozen=True)
class TableTranslatedCell:
    cell_id: str
    text_zh: str


@dataclass(frozen=True)
class TableUnitTranslation:
    block_id: str
    cells: tuple[TableTranslatedCell, ...]

    def for_cell(self, cell_id: str) -> TableTranslatedCell:
        for cell in self.cells:
            if cell.cell_id == cell_id:
                return cell
        raise KeyError(cell_id)


UnitTranslation = SentenceUnitTranslation | TableUnitTranslation


@dataclass(frozen=True)
class AcceptedTranslation:
    """A validated unit translation plus the provider request identity."""

    translation: UnitTranslation
    request_id: str


class TranslationUnitMismatch(ValueError):
    """The adapter returned a unit identity set that differs from the plan."""

    code = "translation_unit_mismatch"


class TableShapeMismatch(ValueError):
    """The translated table changed rows, columns or cell IDs."""

    code = "table_translation_shape_mismatch"


class ProtectedTokenMismatch(ValueError):
    """A protected placeholder was dropped or altered by the model."""

    code = "protected_token_mismatch"


def verify_sentence_batch(unit: SentenceBatchUnit, result: SentenceUnitTranslation) -> None:
    expected = tuple(sentence.sentence_id for sentence in unit.sentences)
    actual = tuple(item.sentence_id for item in result.translations)
    if (
        result.block_id != unit.block_id
        or actual != expected
        or len(set(actual)) != len(actual)
    ):
        raise TranslationUnitMismatch(
            f"translation adapter returned a mismatched ID set for {unit.block_id}"
        )


def verify_table_translation(unit: TableUnit, translation: TableUnitTranslation) -> None:
    if translation.block_id != unit.block_id:
        raise TableShapeMismatch(
            f"translated table block identity changed: {translation.block_id}"
        )
    # Position-sensitive by design (§5.2.2): the model must return the SAME
    # table — header cells, then row cells — so a response that swaps cell IDs
    # between positions binds translations to the wrong cell and is rejected
    # exactly like an added or dropped cell.
    expected_ids = unit.cell_ids
    actual_ids = tuple(cell.cell_id for cell in translation.cells)
    if (
        len(set(actual_ids)) != len(actual_ids)
        or actual_ids != expected_ids
        or len(actual_ids) != len(expected_ids)
    ):
        raise TableShapeMismatch(
            f"translated table {unit.block_id} changed shape or cell identity"
        )
    for cell in translation.cells:
        if not cell.text_zh.strip():
            raise TableShapeMismatch(
                f"translated table {unit.block_id} has an empty cell {cell.cell_id}"
            )


def verify_edited_table_shape(
    original: TableUnitTranslation, edited: TableUnitTranslation
) -> None:
    """A human table edit must keep the exact cell identity sequence (§8.4).

    Order-sensitive by design (§5.2.2/§9.3.3): a cell keeps its row/column
    position, so a reordered-but-same-set edit is a shape change and is
    rejected just like an added or dropped cell.
    """
    expected = tuple(cell.cell_id for cell in original.cells)
    actual = tuple(cell.cell_id for cell in edited.cells)
    if edited.block_id != original.block_id or actual != expected:
        raise TableShapeMismatch(
            f"edited table {original.block_id} changed shape or cell identity"
        )
    for cell in edited.cells:
        if not cell.text_zh.strip():
            raise TableShapeMismatch(
                f"edited table {original.block_id} has an empty cell {cell.cell_id}"
            )


def verify_protected_tokens(
    protected_map: ProtectedTokenMap, translated: tuple[str, ...]
) -> None:
    """Every placeholder must survive exactly once, in its own slot (§8.2).

    Slot-aware by design: 'translated' parallels the wire run lists, and each
    token belongs to the slot it was protected from. A model that swaps two
    placeholders between sentences/cells still shows each exactly once
    globally, but the wrong slot — binding the wrong literal to the wrong
    sentence/cell — so per-slot occurrence is what must equal one.

    Canonical-spelling aware: verification scans every placeholder-shaped
    occurrence in the reply, so a non-canonical lookalike that a plain
    count-and-int() pipeline would miss — leading zeros, non-ASCII digits,
    invented indices or a stray bare sentinel — is rejected instead of
    leaking into a published artifact.
    """
    expected_in_slot: list[set[str]] = [set() for _ in translated]
    for token in protected_map.tokens:
        if not 0 <= token.slot < len(translated):
            raise ProtectedTokenMismatch(
                f"protected token {token.index} has slot {token.slot} outside "
                f"the {len(translated)} translated items"
            )
        expected_in_slot[token.slot].add(token.placeholder)
    for slot, text in enumerate(translated):
        matches = list(_PLACEHOLDER_PATTERN.finditer(text))
        # Every sentinel character must belong to a well-formed placeholder;
        # anything else is a damaged or invented marker.
        if text.count(_PLACEHOLDER) != 2 * len(matches):
            raise ProtectedTokenMismatch(
                f"slot {slot} contains a stray or malformed placeholder marker"
            )
        for match in matches:
            placeholder = match.group(0)
            if placeholder not in expected_in_slot[slot]:
                raise ProtectedTokenMismatch(
                    f"slot {slot} carries placeholder {placeholder!r} which is "
                    "not the canonical spelling of the token protected there"
                )
            expected_in_slot[slot].discard(placeholder)
    # Anything still expected was dropped by the model.
    for slot, remaining in enumerate(expected_in_slot):
        if remaining:
            raise ProtectedTokenMismatch(
                f"slot {slot} dropped placeholder {sorted(remaining)[0]!r}"
            )
