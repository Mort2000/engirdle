from __future__ import annotations

import json
import re
import unicodedata
from collections.abc import Iterable

from engirdle_pc.modules.content.domain.entities import (
    Block,
    BlockKind,
    EditedBlock,
    Sentence,
)
from engirdle_pc.modules.content.domain.errors import InvalidContent
from engirdle_pc.shared.domain.hashing import sha256_text

_LIST_MARKER = re.compile(r"^\s*(?:[-*+]\s+|\d+[.)]\s+)(.+)$")
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


def normalize_text(raw_text: str) -> str:
    normalized = unicodedata.normalize("NFKC", raw_text.replace("\r\n", "\n").replace("\r", "\n"))
    normalized = normalized.translate(_SMART_CHARACTERS)
    normalized = "".join(
        character
        for character in normalized
        if character in "\n\t" or unicodedata.category(character) != "Cc"
    )
    lines = [re.sub(r"[\t ]+", " ", line).strip() for line in normalized.split("\n")]
    result: list[str] = []
    previous_blank = True
    for line in lines:
        if line:
            result.append(line)
            previous_blank = False
        elif not previous_blank:
            result.append("")
            previous_blank = True
    return "\n".join(result).strip()


def segment_text(normalized_text: str) -> tuple[Block, ...]:
    if not normalized_text.strip():
        raise InvalidContent("article body must not be empty")
    candidates: list[tuple[BlockKind, str]] = []
    for chunk in re.split(r"\n\s*\n", normalized_text):
        lines = [line.strip() for line in chunk.splitlines() if line.strip()]
        if not lines:
            continue
        if all(_LIST_MARKER.match(line) for line in lines):
            for line in lines:
                match = _LIST_MARKER.match(line)
                assert match is not None
                candidates.append((BlockKind.LIST_ITEM, match.group(1).strip()))
        elif all(line.startswith(">") for line in lines):
            candidates.append((BlockKind.QUOTE, " ".join(line[1:].strip() for line in lines)))
        else:
            candidates.append((BlockKind.PARAGRAPH, " ".join(lines)))

    sentence_number = 1
    blocks: list[Block] = []
    for block_order, (kind, text) in enumerate(candidates):
        sentences: list[Sentence] = []
        for sentence_order, sentence_text in enumerate(_split_sentences(text)):
            if sentence_text:
                sentences.append(
                    Sentence(
                        sentence_id=f"sentence-{sentence_number}",
                        order=sentence_order,
                        text=sentence_text,
                    )
                )
                sentence_number += 1
        if sentences:
            blocks.append(
                Block(
                    block_id=f"block-{block_order + 1}",
                    kind=kind,
                    order=block_order,
                    sentences=tuple(sentences),
                )
            )
    if not blocks:
        raise InvalidContent("article must contain at least one non-empty block")
    return tuple(blocks)


def _split_sentences(text: str) -> tuple[str, ...]:
    sentences: list[str] = []
    start = 0
    index = 0
    while index < len(text):
        character = text[index]
        if character not in ".!?":
            index += 1
            continue
        if character == "." and _period_is_nonterminal(text, index):
            index += 1
            continue
        end = index + 1
        while end < len(text) and text[end] in ".!?":
            end += 1
        while end < len(text) and text[end] in _CLOSING_PUNCTUATION:
            end += 1
        next_start = end
        while next_start < len(text) and text[next_start].isspace():
            next_start += 1
        if next_start < len(text) and text[next_start].islower():
            index = end
            continue
        sentence = text[start:end].strip()
        if sentence:
            sentences.append(sentence)
        start = next_start
        index = next_start
    remainder = text[start:].strip()
    if remainder:
        sentences.append(remainder)
    return tuple(sentences)


def _period_is_nonterminal(text: str, index: int) -> bool:
    if (
        index > 0
        and index + 1 < len(text)
        and text[index - 1].isdigit()
        and text[index + 1].isdigit()
    ):
        return True
    token_start = index
    while token_start > 0 and (
        text[token_start - 1].isalpha() or text[token_start - 1] == "."
    ):
        token_start -= 1
    raw_token = text[token_start:index]
    token = raw_token.lower()
    if token in _NONTERMINAL_ABBREVIATIONS:
        return True
    if len(raw_token) == 1 and raw_token.isupper():
        return True
    dotted = f"{token}."
    return bool(re.fullmatch(r"(?:[a-z]\.){2,}", dotted))


def materialize_edited_blocks(edited_blocks: Iterable[EditedBlock]) -> tuple[Block, ...]:
    edited = tuple(edited_blocks)
    provided_block_ids = [block.block_id for block in edited if block.block_id is not None]
    provided_sentence_ids = [
        sentence.sentence_id
        for block in edited
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
    next_block_number = 1
    next_sentence_number = 1
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
            sentence_id = edited_sentence.sentence_id or f"sentence-{next_sentence_number}"
            if sentence_id in used_sentence_ids:
                raise InvalidContent(f"duplicate sentence ID: {sentence_id}")
            used_sentence_ids.add(sentence_id)
            next_sentence_number += 1
            sentences.append(Sentence(sentence_id, sentence_order, text))
        if not sentences:
            raise InvalidContent("blocks must contain at least one sentence")
        blocks.append(Block(block_id, edited_block.kind, block_order, tuple(sentences)))
    if not blocks:
        raise InvalidContent("article must contain at least one block")
    return tuple(blocks)


def structure_sha256(blocks: Iterable[Block]) -> str:
    payload = [
        {
            "block_id": block.block_id,
            "kind": block.kind.value,
            "order": block.order,
            "sentences": [
                {
                    "sentence_id": sentence.sentence_id,
                    "order": sentence.order,
                    "text": sentence.text,
                }
                for sentence in block.sentences
            ],
        }
        for block in blocks
    ]
    canonical = json.dumps(
        payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    )
    return sha256_text(canonical)
