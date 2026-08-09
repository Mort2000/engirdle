from __future__ import annotations

import json
import os
import sqlite3
import tempfile
from dataclasses import asdict
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.modules.dictionary_builder.domain import (
    DictionaryArtifact,
    DictionaryBuildRequest,
    DictionaryEntry,
    DictionaryForm,
    ParsedDictionarySource,
    SourceBuildSummary,
)
from engirdle_pc.modules.dictionary_builder.sources import (
    FREEDICT_SOURCE_ID,
    OEWN_SOURCE_ID,
    FreedictTeiSource,
    OewnLmfSource,
    normalize,
)
from engirdle_pc.modules.dictionary_builder.validator import DictionaryPackValidator
from engirdle_pc.shared.infrastructure.hashing import sha256_file

DICTIONARY_ID = "engirdle-en-zh"
SCHEMA_VERSION = 1
BUILDER_VERSION = "1.0.0"

_POS_RANK = {"noun": 0, "verb": 1, "adjective": 2, "adverb": 3, "other": 9}
_MODIFICATIONS = [
    "Unicode NFC normalization, whitespace collapse and Unicode lowercase lookup keys.",
    "Source-preserving sense rows; no cross-source sense merge.",
    "Empty senses are filtered, duplicate translations are collapsed, and TEI markup is flattened.",
    "OEWN explicit forms plus deterministic common English inflection rules are indexed.",
    "Results are ordered by source_rank, pos_rank and source-local ord.",
]


class DictionaryBuilder:
    def __init__(
        self,
        oewn: OewnLmfSource | None = None,
        freedict: FreedictTeiSource | None = None,
        validator: DictionaryPackValidator | None = None,
    ) -> None:
        self._oewn = oewn or OewnLmfSource()
        self._freedict = freedict or FreedictTeiSource()
        self._validator = validator or DictionaryPackValidator(
            Settings().contracts_dir,
            oewn_sha256=self._oewn.expected_sha256,
            freedict_sha256=self._freedict.expected_sha256,
        )

    def build(self, request: DictionaryBuildRequest) -> DictionaryArtifact:
        if request.revision < 1:
            raise ValueError("dictionary revision must be positive")
        if request.output.suffix != ".dictpack":
            raise ValueError("dictionary output must use the .dictpack extension")
        oewn = self._oewn.read(request.oewn_archive)
        freedict = self._freedict.read(request.freedict_archive)
        with tempfile.TemporaryDirectory(prefix="engirdle_dictionary_") as temporary:
            database = Path(temporary) / "dictionary.db"
            self._write_database(database, request.revision, oewn, freedict)
            manifest = self._manifest(request, database, oewn, freedict)
            self._write_package(request.output, database, manifest)
            try:
                self._validator.validate(request.output)
            except Exception:
                request.output.unlink(missing_ok=True)
                raise
        return DictionaryArtifact(
            dictionary_id=DICTIONARY_ID,
            revision=request.revision,
            path=request.output,
            size=request.output.stat().st_size,
            sha256=sha256_file(request.output),
            sources=(
                SourceBuildSummary(
                    source_id=OEWN_SOURCE_ID,
                    input_sha256=sha256_file(request.oewn_archive),
                    counts=oewn.counts,
                ),
                SourceBuildSummary(
                    source_id=FREEDICT_SOURCE_ID,
                    input_sha256=sha256_file(request.freedict_archive),
                    counts=freedict.counts,
                ),
            ),
        )

    @staticmethod
    def _write_database(
        path: Path,
        revision: int,
        oewn: ParsedDictionarySource,
        freedict: ParsedDictionarySource,
    ) -> None:
        entries = sorted(
            (*oewn.entries, *freedict.entries),
            key=lambda item: (
                normalize(item.headword),
                item.source_rank,
                _POS_RANK[item.part_of_speech],
                item.order,
                item.sense_id,
            ),
        )
        forms = sorted(
            {*oewn.forms, *freedict.forms},
            key=lambda item: (
                normalize(item.form),
                item.source_rank,
                item.order,
                normalize(item.lemma),
                item.source_id,
            ),
        )
        connection = sqlite3.connect(path)
        try:
            connection.executescript(
                """
                PRAGMA page_size = 4096;
                PRAGMA journal_mode = DELETE;
                PRAGMA synchronous = OFF;
                CREATE TABLE entries (
                  headword TEXT NOT NULL,
                  normalized_headword TEXT NOT NULL,
                  pos TEXT NOT NULL,
                  sense_id TEXT PRIMARY KEY,
                  gloss_en TEXT,
                  gloss_zh TEXT,
                  pronunciation TEXT,
                  source_id TEXT NOT NULL,
                  source_name TEXT NOT NULL,
                  pos_rank INTEGER NOT NULL,
                  source_rank INTEGER NOT NULL,
                  ord INTEGER NOT NULL,
                  CHECK (gloss_en IS NOT NULL OR gloss_zh IS NOT NULL)
                );
                CREATE TABLE forms (
                  form TEXT NOT NULL,
                  normalized_form TEXT NOT NULL,
                  lemma TEXT NOT NULL,
                  source_id TEXT NOT NULL,
                  pos TEXT,
                  source_rank INTEGER NOT NULL,
                  ord INTEGER NOT NULL,
                  PRIMARY KEY (normalized_form, lemma, source_id, pos)
                ) WITHOUT ROWID;
                CREATE TABLE dictionary_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE INDEX idx_entries_headword_order
                  ON entries(headword, source_rank, pos_rank, ord, sense_id);
                CREATE INDEX idx_entries_normalized_order
                  ON entries(normalized_headword, source_rank, pos_rank, ord, sense_id);
                CREATE INDEX idx_forms_normalized_order
                  ON forms(normalized_form, source_rank, ord, lemma);
                """
            )
            connection.executemany(
                "INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [_entry_row(entry) for entry in entries],
            )
            connection.executemany(
                "INSERT INTO forms VALUES (?, ?, ?, ?, ?, ?, ?)",
                [_form_row(form) for form in forms],
            )
            connection.executemany(
                "INSERT INTO dictionary_meta VALUES (?, ?)",
                (
                    ("dictionary_id", DICTIONARY_ID),
                    ("revision", str(revision)),
                    ("schema_version", str(SCHEMA_VERSION)),
                    ("normalization_version", "unicode-nfc-lower-v1"),
                ),
            )
            connection.commit()
            connection.execute("VACUUM")
        finally:
            connection.close()

    @staticmethod
    def _manifest(
        request: DictionaryBuildRequest,
        database: Path,
        oewn: ParsedDictionarySource,
        freedict: ParsedDictionarySource,
    ) -> dict[str, object]:
        return {
            "format_version": "1.0",
            "dictionary_id": DICTIONARY_ID,
            "revision": request.revision,
            "schema_version": SCHEMA_VERSION,
            "display_name": "Engirdle English-Chinese Offline Dictionary",
            "generated_at": request.generated_at,
            "builder": {
                "name": "engirdle-pc dictionary-builder",
                "version": BUILDER_VERSION,
            },
            "normalization": {
                "algorithm": "Unicode NFC, whitespace collapse and Unicode lowercase",
                "version": "unicode-nfc-lower-v1",
            },
            "database": {
                "path": "dictionary.db",
                "size": database.stat().st_size,
                "sha256": sha256_file(database),
            },
            "sources": [
                {
                    "source_id": OEWN_SOURCE_ID,
                    "version": "2025",
                    "display_name": "Open English WordNet 2025",
                    "direction": "en-en",
                    "input": {
                        "url": "https://en-word.net/static/english-wordnet-2025.xml.gz",
                        "sha256": sha256_file(request.oewn_archive),
                    },
                    "licenses": [
                        {
                            "name": "Creative Commons Attribution 4.0 International",
                            "url": "https://creativecommons.org/licenses/by/4.0/",
                        },
                        {
                            "name": "Princeton WordNet License",
                            "url": "https://wordnet.princeton.edu/license-and-commercial-use",
                        },
                    ],
                    "attributions": [
                        {
                            "name": "Open English WordNet",
                            "url": "https://github.com/globalwordnet/english-wordnet",
                        },
                        {
                            "name": "Princeton WordNet",
                            "url": "https://wordnet.princeton.edu/",
                        },
                    ],
                    "counts": asdict(oewn.counts),
                    "extraction_note": (
                        "Extract lemma, POS, namespace-qualified sense/synset identity, "
                        "English definition and explicit/generated forms from the core "
                        "2025 LMF release."
                    ),
                },
                {
                    "source_id": FREEDICT_SOURCE_ID,
                    "version": "2025.11.23",
                    "display_name": "FreeDict English-Chinese",
                    "direction": "en-zh",
                    "input": {
                        "url": (
                            "https://download.freedict.org/dictionaries/eng-zho/2025.11.23/"
                            "freedict-eng-zho-2025.11.23.src.tar.xz"
                        ),
                        "sha256": sha256_file(request.freedict_archive),
                    },
                    "licenses": [
                        {
                            "name": "Creative Commons Attribution-ShareAlike 3.0",
                            "url": "https://creativecommons.org/licenses/by-sa/3.0/",
                        }
                    ],
                    "attributions": [
                        {"name": "FreeDict", "url": "https://freedict.org/"},
                        {"name": "WikDict", "url": "https://www.wikdict.com/"},
                        {"name": "DBnary", "url": "https://kaiko.getalp.org/about-dbnary/"},
                        {"name": "Wiktionary", "url": "https://www.wiktionary.org/"},
                    ],
                    "counts": asdict(freedict.counts),
                    "extraction_note": (
                        "Flatten TEI markup; extract English headword, POS, pronunciation, "
                        "optional definition and Chinese translations; remove empty senses "
                        "and duplicate translations."
                    ),
                },
            ],
            "modifications": _MODIFICATIONS,
            "license_files": [
                "licenses/oewn-2025.txt",
                "licenses/freedict-eng-zho-2025.11.23.txt",
            ],
        }

    @staticmethod
    def _write_package(
        output: Path,
        database: Path,
        manifest: dict[str, object],
    ) -> None:
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_suffix(".dictpack.tmp")
        temporary.unlink(missing_ok=True)
        manifest_bytes = (
            json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode()
        try:
            with ZipFile(temporary, "w") as package:
                _write_zip_bytes(package, "manifest.json", manifest_bytes)
                _write_zip_bytes(package, "dictionary.db", database.read_bytes())
                _write_zip_bytes(package, "licenses/oewn-2025.txt", _oewn_license_notice())
                _write_zip_bytes(
                    package,
                    "licenses/freedict-eng-zho-2025.11.23.txt",
                    _freedict_license_notice(),
                )
            os.replace(temporary, output)
        finally:
            temporary.unlink(missing_ok=True)


def _entry_row(entry: DictionaryEntry) -> tuple[object, ...]:
    return (
        entry.headword,
        normalize(entry.headword),
        entry.part_of_speech,
        entry.sense_id,
        entry.gloss_en,
        entry.gloss_zh,
        entry.pronunciation,
        entry.source_id,
        entry.source_name,
        _POS_RANK[entry.part_of_speech],
        entry.source_rank,
        entry.order,
    )


def _form_row(form: DictionaryForm) -> tuple[object, ...]:
    return (
        form.form,
        normalize(form.form),
        form.lemma,
        form.source_id,
        form.part_of_speech,
        form.source_rank,
        form.order,
    )


def _write_zip_bytes(package: ZipFile, path: str, payload: bytes) -> None:
    info = ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = ZIP_DEFLATED
    info.external_attr = 0o100644 << 16
    package.writestr(info, payload)


def _oewn_license_notice() -> bytes:
    return (
        b"Open English WordNet 2025\n"
        b"License: CC BY 4.0 https://creativecommons.org/licenses/by/4.0/\n"
        b"Project and full notices: https://github.com/globalwordnet/english-wordnet/blob/main/LICENSE.md\n"
        b"Includes material derived from Princeton WordNet; retain its notice and disclaimer:\n"
        b"https://wordnet.princeton.edu/license-and-commercial-use\n"
    )


def _freedict_license_notice() -> bytes:
    return (
        b"FreeDict eng-zho 2025.11.23\n"
        b"License: CC BY-SA 3.0 https://creativecommons.org/licenses/by-sa/3.0/\n"
        b"Attribution: FreeDict, WikDict, DBnary and Wiktionary.\n"
        b"Source: https://download.freedict.org/dictionaries/eng-zho/2025.11.23/\n"
    )
