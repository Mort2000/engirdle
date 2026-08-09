from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class DictionaryEntry:
    headword: str
    part_of_speech: str
    sense_id: str
    gloss_en: str | None
    pronunciation: str | None
    synset_ili: str | None
    source_id: str
    source_name: str
    source_rank: int
    order: int


@dataclass(frozen=True)
class DictionaryForm:
    form: str
    lemma: str
    part_of_speech: str | None
    source_id: str
    source_rank: int
    order: int


@dataclass(frozen=True)
class SourceCounts:
    original_headwords: int
    filtered_headwords: int
    final_headwords: int


@dataclass(frozen=True)
class ParsedDictionarySource:
    entries: tuple[DictionaryEntry, ...]
    forms: tuple[DictionaryForm, ...]
    counts: SourceCounts


@dataclass(frozen=True)
class ChineseLemma:
    synset_ili: str
    source_sense_id: str
    raw_lemma: str
    display_lemma: str
    source_id: str
    order: int


@dataclass(frozen=True)
class ParsedChineseSource:
    lemmas: tuple[ChineseLemma, ...]
    counts: SourceCounts


@dataclass(frozen=True)
class SenseTranslation:
    sense_id: str
    source_sense_id: str
    raw_lemma: str
    display_lemma: str
    source_id: str
    order: int


@dataclass(frozen=True)
class DictionaryBuildRequest:
    oewn_archive: Path
    omw_cmn_archive: Path
    output: Path
    revision: int
    generated_at: str


@dataclass(frozen=True)
class SourceBuildSummary:
    source_id: str
    input_sha256: str
    counts: SourceCounts


@dataclass(frozen=True)
class DictionaryArtifact:
    dictionary_id: str
    revision: int
    path: Path
    size: int
    sha256: str
    sources: tuple[SourceBuildSummary, ...]
