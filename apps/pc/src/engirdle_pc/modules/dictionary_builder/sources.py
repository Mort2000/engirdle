from __future__ import annotations

import gzip
import hashlib
import re
import tarfile
import unicodedata
import xml.etree.ElementTree as ET
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

from engirdle_pc.modules.dictionary_builder.domain import (
    DictionaryEntry,
    DictionaryForm,
    ParsedDictionarySource,
    SourceCounts,
)

OEWN_SOURCE_ID = "oewn-2025"
FREEDICT_SOURCE_ID = "freedict-eng-zho-2025.11.23"
OEWN_2025_SHA256 = "9ca6d1dcb75f822fdd66617f7d9da48142ace38dd544d6ad5e2feca1674ad3fe"
FREEDICT_2025_11_23_SHA256 = "78f6909786861809886201827e5e3d55dbf8e12f753d7a7183e785dbc574de8b"

_XML_ID = "{http://www.w3.org/XML/1998/namespace}id"
_XML_LANG = "{http://www.w3.org/XML/1998/namespace}lang"
_WHITESPACE = re.compile(r"\s+")
_POS_NAMES = {
    "n": "noun",
    "noun": "noun",
    "v": "verb",
    "verb": "verb",
    "a": "adjective",
    "s": "adjective",
    "adj": "adjective",
    "adjective": "adjective",
    "r": "adverb",
    "adv": "adverb",
    "adverb": "adverb",
}


@dataclass(frozen=True)
class _FreedictSenseRow:
    node: ET.Element
    gloss_en: str | None
    gloss_zh: str | None


class OewnLmfSource:
    """Streaming reader for the official OEWN 2025 GWN-LMF gzip release."""

    def __init__(self, *, expected_sha256: str = OEWN_2025_SHA256) -> None:
        self._expected_sha256 = expected_sha256

    @property
    def expected_sha256(self) -> str:
        return self._expected_sha256

    def read(self, archive: Path) -> ParsedDictionarySource:
        if archive.name not in {
            "english-wordnet-2025.xml.gz",
            "english-wordnet-2025.xml",
        }:
            raise ValueError("OEWN input must be the official 2025 core LMF release")
        _require_snapshot(archive, self._expected_sha256, "OEWN 2025")
        self._validate_metadata(archive)
        synsets = self._read_synsets(archive)
        entries: list[DictionaryEntry] = []
        forms: list[DictionaryForm] = []
        original = 0
        filtered = 0
        for lexical_entry in self._elements(archive, "LexicalEntry"):
            original += 1
            lemma_node = _first_descendant(lexical_entry, "Lemma")
            lemma = _written_form(lemma_node)
            pos = _pos(lemma_node.attrib.get("partOfSpeech") if lemma_node is not None else None)
            senses = list(_descendants(lexical_entry, "Sense"))
            accepted = 0
            for sense_order, sense in enumerate(senses):
                synset_id = sense.attrib.get("synset", "")
                synset = synsets.get(synset_id)
                gloss = synset[1] if synset is not None else None
                sense_pos = pos if pos != "other" else (synset[0] if synset else "other")
                sense_id = sense.attrib.get("id", "")
                if not lemma or not gloss or not sense_id:
                    continue
                entries.append(
                    DictionaryEntry(
                        headword=lemma,
                        part_of_speech=sense_pos,
                        sense_id=f"{OEWN_SOURCE_ID}/{sense_id}",
                        gloss_en=gloss,
                        gloss_zh=None,
                        pronunciation=None,
                        source_id=OEWN_SOURCE_ID,
                        source_name="Open English WordNet 2025",
                        source_rank=0,
                        order=sense_order,
                    )
                )
                accepted += 1
            if not lemma or accepted == 0:
                filtered += 1
                continue
            explicit_forms = {
                form
                for node in _descendants(lexical_entry, "Form")
                if (form := _written_form(node)) and normalize(form) != normalize(lemma)
            }
            all_forms = explicit_forms | _generated_forms(
                lemma,
                pos,
                has_explicit_forms=bool(explicit_forms),
            )
            for form_order, form in enumerate(
                sorted(all_forms, key=lambda value: (normalize(value), value))
            ):
                forms.append(
                    DictionaryForm(
                        form=form,
                        lemma=lemma,
                        part_of_speech=pos,
                        source_id=OEWN_SOURCE_ID,
                        source_rank=0,
                        order=form_order,
                    )
                )
        return ParsedDictionarySource(
            entries=tuple(entries),
            forms=tuple(forms),
            counts=SourceCounts(
                original_headwords=original,
                filtered_headwords=filtered,
                final_headwords=len({normalize(entry.headword) for entry in entries}),
            ),
        )

    def _read_synsets(self, archive: Path) -> dict[str, tuple[str, str]]:
        result: dict[str, tuple[str, str]] = {}
        for synset in self._elements(archive, "Synset"):
            synset_id = synset.attrib.get("id", "")
            definition = _first_text(synset, "Definition")
            if synset_id and definition:
                result[synset_id] = (_pos(synset.attrib.get("partOfSpeech")), definition)
        return result

    @staticmethod
    def _validate_metadata(archive: Path) -> None:
        opener = gzip.open if archive.suffix == ".gz" else Path.open
        with opener(archive, "rb") as stream:
            for _, element in ET.iterparse(stream, events=("start",)):
                if _local_name(element.tag) != "Lexicon":
                    continue
                if (
                    element.attrib.get("id") != "oewn"
                    or element.attrib.get("language") != "en"
                    or element.attrib.get("version") != "2025"
                    or element.attrib.get("license")
                    != "https://creativecommons.org/licenses/by/4.0"
                ):
                    raise ValueError("OEWN internal release metadata is not the frozen 2025 core")
                return
        raise ValueError("OEWN input does not contain Lexicon metadata")

    @staticmethod
    def _elements(archive: Path, wanted: str) -> Iterator[ET.Element]:
        opener = gzip.open if archive.suffix == ".gz" else Path.open
        with opener(archive, "rb") as stream:
            for _, element in ET.iterparse(stream, events=("end",)):
                if _local_name(element.tag) == wanted:
                    yield element
                    element.clear()


class FreedictTeiSource:
    """Streaming reader for the fixed official FreeDict eng-zho TEI source tarball."""

    _MAX_TEI_BYTES = 256 * 1024 * 1024

    def __init__(self, *, expected_sha256: str = FREEDICT_2025_11_23_SHA256) -> None:
        self._expected_sha256 = expected_sha256

    @property
    def expected_sha256(self) -> str:
        return self._expected_sha256

    def read(self, archive: Path) -> ParsedDictionarySource:
        if archive.name != "freedict-eng-zho-2025.11.23.src.tar.xz":
            raise ValueError(
                "FreeDict input must be the official eng-zho 2025.11.23 source package"
            )
        _require_snapshot(archive, self._expected_sha256, "FreeDict eng-zho 2025.11.23")
        entries: list[DictionaryEntry] = []
        forms: list[DictionaryForm] = []
        original = 0
        filtered = 0
        edition: str | None = None
        with tarfile.open(archive, "r:xz") as tar:
            candidates = [
                member
                for member in tar.getmembers()
                if member.isfile() and member.name.endswith(".tei")
            ]
            if len(candidates) != 1 or candidates[0].size > self._MAX_TEI_BYTES:
                raise ValueError("FreeDict source package must contain one bounded TEI file")
            extracted = tar.extractfile(candidates[0])
            if extracted is None:
                raise ValueError("FreeDict TEI source is unreadable")
            for _, entry_node in ET.iterparse(extracted, events=("end",)):
                local_name = _local_name(entry_node.tag)
                if local_name == "edition" and edition is None:
                    edition = _text(entry_node)
                if local_name != "entry":
                    continue
                original += 1
                headword = _lemma_from_tei(entry_node)
                entry_pos = _pos(_first_text(entry_node, "pos"))
                pronunciation = _first_text(entry_node, "pron")
                accepted = 0
                sense_rows = list(_freedict_sense_rows(entry_node))
                for sense_order, sense_row in enumerate(sense_rows):
                    sense = sense_row.node
                    gloss_en = sense_row.gloss_en
                    gloss_zh = sense_row.gloss_zh
                    if not headword or (not gloss_en and not gloss_zh):
                        continue
                    sense_pos = _pos(_first_text(sense, "pos"))
                    if sense_pos == "other":
                        sense_pos = entry_pos
                    raw_id = sense.attrib.get(_XML_ID) or sense.attrib.get("id")
                    if not raw_id:
                        stable = "|".join(
                            [headword, sense_pos, gloss_en or "", gloss_zh or "", str(sense_order)]
                        )
                        raw_id = hashlib.sha256(stable.encode()).hexdigest()[:20]
                    entries.append(
                        DictionaryEntry(
                            headword=headword,
                            part_of_speech=sense_pos,
                            sense_id=f"{FREEDICT_SOURCE_ID}/{raw_id}",
                            gloss_en=gloss_en,
                            gloss_zh=gloss_zh,
                            pronunciation=pronunciation,
                            source_id=FREEDICT_SOURCE_ID,
                            source_name="FreeDict English-Chinese 2025.11.23",
                            source_rank=1,
                            order=sense_order,
                        )
                    )
                    accepted += 1
                if not headword or accepted == 0:
                    filtered += 1
                    entry_node.clear()
                    continue
                inflected = {
                    text
                    for form_node in _descendants(entry_node, "form")
                    if form_node.attrib.get("type") not in {None, "lemma"}
                    for text in [_first_text(form_node, "orth")]
                    if text and normalize(text) != normalize(headword)
                }
                for form_order, form in enumerate(
                    sorted(inflected, key=lambda value: (normalize(value), value))
                ):
                    forms.append(
                        DictionaryForm(
                            form=form,
                            lemma=headword,
                            part_of_speech=entry_pos,
                            source_id=FREEDICT_SOURCE_ID,
                            source_rank=1,
                            order=form_order,
                        )
                    )
                entry_node.clear()
        if edition != "2025.11.23":
            raise ValueError("FreeDict internal edition is not the frozen 2025.11.23 release")
        return ParsedDictionarySource(
            entries=tuple(entries),
            forms=tuple(forms),
            counts=SourceCounts(
                original_headwords=original,
                filtered_headwords=filtered,
                final_headwords=len({normalize(entry.headword) for entry in entries}),
            ),
        )


def normalize(value: str) -> str:
    return _WHITESPACE.sub(" ", unicodedata.normalize("NFC", value).strip()).lower()


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _descendants(element: ET.Element, name: str) -> Iterator[ET.Element]:
    return (node for node in element.iter() if _local_name(node.tag) == name)


def _first_descendant(element: ET.Element, name: str) -> ET.Element | None:
    return next(_descendants(element, name), None)


def _text(element: ET.Element) -> str | None:
    value = _WHITESPACE.sub(" ", "".join(element.itertext()).strip())
    return value or None


def _first_text(element: ET.Element, name: str) -> str | None:
    node = _first_descendant(element, name)
    return _text(node) if node is not None else None


def _written_form(element: ET.Element | None) -> str:
    if element is None:
        return ""
    raw = element.attrib.get("writtenForm") or _first_text(element, "FormRepresentation")
    return _WHITESPACE.sub(" ", (raw or "").replace("_", " ").strip())


def _lemma_from_tei(entry: ET.Element) -> str:
    lemma_forms = [
        node
        for node in _descendants(entry, "form")
        if node.attrib.get("type") in {None, "lemma", "headword"}
    ]
    for form in lemma_forms:
        orth = _first_text(form, "orth")
        if orth:
            return orth
    return _first_text(entry, "orth") or ""


def _freedict_sense_rows(
    entry: ET.Element,
) -> Iterator[_FreedictSenseRow]:
    top_level = [node for node in entry if _local_name(node.tag) == "sense"]
    for outer in top_level or [entry]:
        outer_english, outer_chinese = _freedict_direct_glosses(outer)
        children = [node for node in outer if _local_name(node.tag) == "sense"]
        if not children:
            yield _FreedictSenseRow(
                node=outer,
                gloss_en=_join_unique(outer_english),
                gloss_zh=_join_unique(outer_chinese),
            )
            continue
        for child in children:
            child_english, child_chinese = _freedict_direct_glosses(child)
            yield _FreedictSenseRow(
                node=child,
                gloss_en=_join_unique([*outer_english, *child_english]),
                gloss_zh=_join_unique([*outer_chinese, *child_chinese]),
            )


def _freedict_direct_glosses(sense: ET.Element) -> tuple[list[str], list[str]]:
    english: list[str] = []
    chinese: list[str] = []
    for node in _without_nested_senses(sense):
        local = _local_name(node.tag)
        if local not in {"def", "quote"}:
            continue
        value = _text(node)
        if not value:
            continue
        language = (node.attrib.get(_XML_LANG) or node.attrib.get("lang") or "").lower()
        if local == "def" and language not in {"zh", "zho", "chi"}:
            english.append(value)
        else:
            chinese.append(value)
    return english, chinese


def _without_nested_senses(element: ET.Element) -> Iterator[ET.Element]:
    for child in element:
        if _local_name(child.tag) == "sense":
            continue
        yield child
        yield from _without_nested_senses(child)


def _join_unique(values: list[str]) -> str | None:
    unique = list(dict.fromkeys(values))
    return "; ".join(unique) if unique else None


def _pos(raw: str | None) -> str:
    return _POS_NAMES.get((raw or "").strip().lower().rstrip("."), "other")


def _generated_forms(
    lemma: str,
    part_of_speech: str,
    *,
    has_explicit_forms: bool = False,
) -> set[str]:
    if " " in lemma or "-" in lemma or not lemma.isalpha():
        return set()
    lower = lemma.lower()
    irregular = {
        ("be", "verb"): {"am", "is", "are", "was", "were", "been", "being"},
        ("go", "verb"): {"goes", "went", "gone", "going"},
        ("have", "verb"): {"has", "had", "having"},
        ("take", "verb"): {"takes", "took", "taken", "taking"},
        ("make", "verb"): {"makes", "made", "making"},
        ("run", "verb"): {"runs", "ran", "running"},
        ("child", "noun"): {"children"},
        ("man", "noun"): {"men"},
        ("woman", "noun"): {"women"},
        ("mouse", "noun"): {"mice"},
    }
    irregular_forms = irregular.get((lower, part_of_speech))
    if irregular_forms is not None:
        return set(irregular_forms)
    if has_explicit_forms:
        # OEWN's explicit Form nodes encode spelling-sensitive inflections
        # (for example stopped/stopping). Only add the spelling-safe present
        # tense here so a generic suffix rule cannot reintroduce stoped/stoping.
        return {_third_person(lower)} if part_of_speech == "verb" else set()
    forms: set[str] = set()
    if part_of_speech == "noun":
        forms.add(_plural(lower))
    elif part_of_speech == "verb":
        forms.update({_third_person(lower), _past(lower), _present_participle(lower)})
    elif part_of_speech == "adjective" and len(lower) <= 8:
        forms.update({_comparative(lower), _superlative(lower)})
    forms.discard(lower)
    return forms


def _require_snapshot(path: Path, expected_sha256: str, label: str) -> None:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected_sha256:
        raise ValueError(f"{label} snapshot sha256 does not match the frozen release")


def _plural(word: str) -> str:
    if word.endswith(("s", "x", "z", "ch", "sh")):
        return f"{word}es"
    if word.endswith("y") and len(word) > 1 and word[-2] not in "aeiou":
        return f"{word[:-1]}ies"
    return f"{word}s"


def _third_person(word: str) -> str:
    return _plural(word)


def _past(word: str) -> str:
    if word.endswith("e"):
        return f"{word}d"
    if word.endswith("y") and len(word) > 1 and word[-2] not in "aeiou":
        return f"{word[:-1]}ied"
    return f"{word}ed"


def _present_participle(word: str) -> str:
    if word.endswith("ie"):
        return f"{word[:-2]}ying"
    if word.endswith("e") and not word.endswith("ee"):
        return f"{word[:-1]}ing"
    return f"{word}ing"


def _comparative(word: str) -> str:
    return f"{word[:-1]}ier" if word.endswith("y") else f"{word}er"


def _superlative(word: str) -> str:
    return f"{word[:-1]}iest" if word.endswith("y") else f"{word}est"
