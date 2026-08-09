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
    ChineseLemma,
    DictionaryEntry,
    DictionaryForm,
    ParsedChineseSource,
    ParsedDictionarySource,
    SourceCounts,
)

OEWN_SOURCE_ID = "oewn-2025"
OMW_CMN_SOURCE_ID = "omw-cmn:2.0"
OEWN_2025_SHA256 = "9ca6d1dcb75f822fdd66617f7d9da48142ace38dd544d6ad5e2feca1674ad3fe"
OMW_CMN_2_0_SHA256 = "7d07af60a6ced0cedc4ca114d0b60a796d3f138df0f3be21f6322e53d004e91c"

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
class _OewnSynset:
    part_of_speech: str
    definition: str
    ili: str | None


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
                synset = synsets.get(sense.attrib.get("synset", ""))
                gloss = synset.definition if synset is not None else None
                sense_pos = pos if pos != "other" else (
                    synset.part_of_speech if synset is not None else "other"
                )
                sense_id = sense.attrib.get("id", "")
                if not lemma or not gloss or not sense_id:
                    continue
                entries.append(
                    DictionaryEntry(
                        headword=lemma,
                        part_of_speech=sense_pos,
                        sense_id=f"{OEWN_SOURCE_ID}/{sense_id}",
                        gloss_en=gloss,
                        pronunciation=None,
                        synset_ili=synset.ili if synset is not None else None,
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

    def _read_synsets(self, archive: Path) -> dict[str, _OewnSynset]:
        result: dict[str, _OewnSynset] = {}
        for synset in self._elements(archive, "Synset"):
            synset_id = synset.attrib.get("id", "")
            definition = _first_text(synset, "Definition")
            if synset_id and definition:
                result[synset_id] = _OewnSynset(
                    part_of_speech=_pos(synset.attrib.get("partOfSpeech")),
                    definition=definition,
                    ili=synset.attrib.get("ili") or None,
                )
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


class OmwCmnLmfSource:
    """Reader for the frozen Chinese Open Wordnet 2.0 WN-LMF archive."""

    _XML_PATH = "omw-cmn/omw-cmn.xml"
    _LICENSE_PATH = "omw-cmn/LICENSE"
    _MAX_XML_BYTES = 256 * 1024 * 1024
    _MAX_LICENSE_BYTES = 1024 * 1024

    def __init__(self, *, expected_sha256: str = OMW_CMN_2_0_SHA256) -> None:
        self._expected_sha256 = expected_sha256

    @property
    def expected_sha256(self) -> str:
        return self._expected_sha256

    def read(self, archive: Path) -> ParsedChineseSource:
        if archive.name != "omw-cmn-2.0.tar.xz":
            raise ValueError("Chinese Open Wordnet input must be the official 2.0 archive")
        _require_snapshot(archive, self._expected_sha256, "Chinese Open Wordnet 2.0")
        self._validate_archive(archive)
        synset_ilis = self._read_synset_ilis(archive)
        lemmas: list[ChineseLemma] = []
        original = 0
        filtered = 0
        for lexical_entry in self._elements(archive, "LexicalEntry"):
            original += 1
            lemma_node = _first_descendant(lexical_entry, "Lemma")
            raw_lemma = _raw_written_form(lemma_node)
            display_lemma = display_chinese_lemma(raw_lemma)
            accepted = 0
            for sense in _descendants(lexical_entry, "Sense"):
                raw_sense_id = sense.attrib.get("id", "")
                ili = synset_ilis.get(sense.attrib.get("synset", ""))
                if not raw_lemma or not display_lemma or not raw_sense_id or not ili:
                    continue
                lemmas.append(
                    ChineseLemma(
                        synset_ili=ili,
                        source_sense_id=f"{OMW_CMN_SOURCE_ID}/{raw_sense_id}",
                        raw_lemma=raw_lemma,
                        display_lemma=display_lemma,
                        source_id=OMW_CMN_SOURCE_ID,
                        order=len(lemmas),
                    )
                )
                accepted += 1
            if accepted == 0:
                filtered += 1
        return ParsedChineseSource(
            lemmas=tuple(lemmas),
            counts=SourceCounts(
                original_headwords=original,
                filtered_headwords=filtered,
                final_headwords=len({lemma.display_lemma for lemma in lemmas}),
            ),
        )

    def _validate_archive(self, archive: Path) -> None:
        with tarfile.open(archive, "r:xz") as package:
            members = {member.name: member for member in package.getmembers() if member.isfile()}
            xml = members.get(self._XML_PATH)
            license_member = members.get(self._LICENSE_PATH)
            if (
                xml is None
                or license_member is None
                or xml.size > self._MAX_XML_BYTES
                or license_member.size > self._MAX_LICENSE_BYTES
            ):
                raise ValueError("Chinese Open Wordnet archive layout is invalid")
            license_stream = package.extractfile(license_member)
            if license_stream is None or b"Chinese Open Wordnet Copyright 2013,2014" not in (
                license_stream.read()
            ):
                raise ValueError("Chinese Open Wordnet license notice is missing")
        found_lexicon = False
        found_requires = False
        for event, element in self._parse(archive, events=("start",)):
            del event
            local_name = _local_name(element.tag)
            if local_name == "Lexicon":
                found_lexicon = True
                if (
                    element.attrib.get("id") != "omw-cmn"
                    or element.attrib.get("language") != "cmn-Hans"
                    or element.attrib.get("version") != "2.0"
                    or element.attrib.get("license") != "wordnet"
                ):
                    raise ValueError("Chinese Open Wordnet metadata is not the frozen 2.0 release")
            elif local_name == "Requires":
                found_requires = True
                if (
                    element.attrib.get("ref") != "omw-en"
                    or element.attrib.get("version") != "2.0"
                ):
                    raise ValueError("Chinese Open Wordnet dependency metadata is invalid")
                break
        if not found_lexicon or not found_requires:
            raise ValueError("Chinese Open Wordnet metadata is incomplete")

    def _read_synset_ilis(self, archive: Path) -> dict[str, str]:
        return {
            synset_id: ili
            for synset in self._elements(archive, "Synset")
            if (synset_id := synset.attrib.get("id", ""))
            and (ili := synset.attrib.get("ili", ""))
        }

    def _elements(self, archive: Path, wanted: str) -> Iterator[ET.Element]:
        for _, element in self._parse(archive, events=("end",)):
            if _local_name(element.tag) == wanted:
                yield element
                element.clear()

    def _parse(
        self,
        archive: Path,
        *,
        events: tuple[str, ...],
    ) -> Iterator[tuple[str, ET.Element]]:
        with tarfile.open(archive, "r:xz") as package:
            member = package.getmember(self._XML_PATH)
            stream = package.extractfile(member)
            if stream is None:
                raise ValueError("Chinese Open Wordnet XML is unreadable")
            yield from ET.iterparse(stream, events=events)


def normalize(value: str) -> str:
    return _WHITESPACE.sub(" ", unicodedata.normalize("NFC", value).strip()).lower()


def display_chinese_lemma(raw: str) -> str:
    value = raw.replace("+的", "的").replace("+地", "地")
    return _WHITESPACE.sub(" ", unicodedata.normalize("NFC", value).strip())


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


def _raw_written_form(element: ET.Element | None) -> str:
    if element is None:
        return ""
    return element.attrib.get("writtenForm", "")


def _written_form(element: ET.Element | None) -> str:
    if element is None:
        return ""
    raw = element.attrib.get("writtenForm") or _first_text(element, "FormRepresentation")
    return _WHITESPACE.sub(" ", (raw or "").replace("_", " ").strip())


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
