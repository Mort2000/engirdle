from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class DictionaryEntry:
    headword: str
    part_of_speech: str
    sense_id: str
    gloss_en: str | None
    gloss_zh: str | None
    pronunciation: str | None
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
class DictionaryBuildRequest:
    oewn_archive: Path
    freedict_archive: Path
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
