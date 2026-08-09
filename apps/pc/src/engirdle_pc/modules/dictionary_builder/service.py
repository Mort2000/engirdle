from __future__ import annotations

import json
import os
import sqlite3
import tempfile
from collections import defaultdict
from dataclasses import asdict
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.modules.dictionary_builder.domain import (
    ChineseLemma,
    DictionaryArtifact,
    DictionaryBuildRequest,
    DictionaryEntry,
    DictionaryForm,
    ParsedChineseSource,
    ParsedDictionarySource,
    SenseTranslation,
    SourceBuildSummary,
)
from engirdle_pc.modules.dictionary_builder.sources import (
    OEWN_SOURCE_ID,
    OMW_CMN_SOURCE_ID,
    OewnLmfSource,
    OmwCmnLmfSource,
    normalize,
)
from engirdle_pc.modules.dictionary_builder.validator import DictionaryPackValidator
from engirdle_pc.shared.infrastructure.hashing import sha256_file

DICTIONARY_ID = "engirdle-en-zh"
SCHEMA_VERSION = 2
BUILDER_VERSION = "2.0.0"

_POS_RANK = {"noun": 0, "verb": 1, "adjective": 2, "adverb": 3, "other": 9}
_MODIFICATIONS = [
    "Unicode NFC normalization, whitespace collapse and Unicode lowercase lookup keys.",
    "OEWN 2025 senses are the only entries and form index source.",
    "Chinese Open Wordnet lemmas are joined to OEWN senses only by identical ILI.",
    "Raw Chinese lemmas are retained; display lemmas remove only +的 and +地 markers.",
    "Chinese display lemmas are ordered and deduplicated within each OEWN sense.",
]


class DictionaryBuilder:
    def __init__(
        self,
        oewn: OewnLmfSource | None = None,
        omw_cmn: OmwCmnLmfSource | None = None,
        validator: DictionaryPackValidator | None = None,
    ) -> None:
        self._oewn = oewn or OewnLmfSource()
        self._omw_cmn = omw_cmn or OmwCmnLmfSource()
        self._validator = validator or DictionaryPackValidator(
            Settings().contracts_dir,
            oewn_sha256=self._oewn.expected_sha256,
            omw_cmn_sha256=self._omw_cmn.expected_sha256,
        )

    def build(self, request: DictionaryBuildRequest) -> DictionaryArtifact:
        if request.revision < 1:
            raise ValueError("dictionary revision must be positive")
        if request.output.suffix != ".dictpack":
            raise ValueError("dictionary output must use the .dictpack extension")
        oewn = self._oewn.read(request.oewn_archive)
        omw_cmn = self._omw_cmn.read(request.omw_cmn_archive)
        translations = _align_translations(oewn, omw_cmn)
        with tempfile.TemporaryDirectory(prefix="engirdle_dictionary_") as temporary:
            database = Path(temporary) / "dictionary.db"
            self._write_database(database, request.revision, oewn, translations)
            manifest = self._manifest(request, database, oewn, omw_cmn)
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
                    source_id=OMW_CMN_SOURCE_ID,
                    input_sha256=sha256_file(request.omw_cmn_archive),
                    counts=omw_cmn.counts,
                ),
            ),
        )

    @staticmethod
    def _write_database(
        path: Path,
        revision: int,
        oewn: ParsedDictionarySource,
        translations: tuple[SenseTranslation, ...],
    ) -> None:
        entries = sorted(
            oewn.entries,
            key=lambda item: (
                normalize(item.headword),
                _POS_RANK[item.part_of_speech],
                item.order,
                item.sense_id,
            ),
        )
        forms = sorted(
            set(oewn.forms),
            key=lambda item: (
                normalize(item.form),
                item.order,
                normalize(item.lemma),
                item.source_id,
            ),
        )
        connection = sqlite3.connect(path)
        try:
            connection.execute("PRAGMA foreign_keys = ON")
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
                  gloss_en TEXT NOT NULL,
                  pronunciation TEXT,
                  synset_ili TEXT,
                  source_id TEXT NOT NULL,
                  source_name TEXT NOT NULL,
                  pos_rank INTEGER NOT NULL,
                  source_rank INTEGER NOT NULL,
                  ord INTEGER NOT NULL,
                  CHECK (NULLIF(TRIM(gloss_en), '') IS NOT NULL)
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
                CREATE TABLE sense_translations (
                  sense_id TEXT NOT NULL REFERENCES entries(sense_id),
                  source_sense_id TEXT NOT NULL,
                  raw_lemma TEXT NOT NULL,
                  display_lemma TEXT NOT NULL,
                  source_id TEXT NOT NULL,
                  ord INTEGER NOT NULL,
                  PRIMARY KEY (sense_id, source_sense_id),
                  UNIQUE (sense_id, display_lemma)
                ) WITHOUT ROWID;
                CREATE TABLE dictionary_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE INDEX idx_entries_headword_order
                  ON entries(headword, source_rank, pos_rank, ord, sense_id);
                CREATE INDEX idx_entries_normalized_order
                  ON entries(normalized_headword, source_rank, pos_rank, ord, sense_id);
                CREATE INDEX idx_forms_normalized_order
                  ON forms(normalized_form, source_rank, ord, lemma);
                CREATE INDEX idx_sense_translations_sense_order
                  ON sense_translations(sense_id, ord, source_sense_id);
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
                "INSERT INTO sense_translations VALUES (?, ?, ?, ?, ?, ?)",
                [_translation_row(translation) for translation in translations],
            )
            connection.executemany(
                "INSERT INTO dictionary_meta VALUES (?, ?)",
                (
                    ("dictionary_id", DICTIONARY_ID),
                    ("revision", str(revision)),
                    ("schema_version", str(SCHEMA_VERSION)),
                    ("normalization_version", "unicode-nfc-lower-v1"),
                    ("translation_alignment", "exact-ili-v1"),
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
        omw_cmn: ParsedChineseSource,
    ) -> dict[str, object]:
        return {
            "format_version": "2.0",
            "dictionary_id": DICTIONARY_ID,
            "revision": request.revision,
            "schema_version": SCHEMA_VERSION,
            "display_name": "Engirdle OEWN / Chinese Open Wordnet Dictionary",
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
                        "Extract OEWN lemma, POS, sense identity, ILI, English definition "
                        "and explicit/generated forms from the core 2025 LMF release."
                    ),
                },
                {
                    "source_id": OMW_CMN_SOURCE_ID,
                    "version": "2.0",
                    "display_name": "Chinese Open Wordnet 2.0",
                    "direction": "zh",
                    "input": {
                        "url": (
                            "https://github.com/omwn/omw-data/releases/download/v2.0/"
                            "omw-cmn-2.0.tar.xz"
                        ),
                        "sha256": sha256_file(request.omw_cmn_archive),
                    },
                    "licenses": [
                        {
                            "name": "Chinese Open Wordnet License",
                            "url": "https://github.com/omwn/omw-data/blob/main/wns/cow/LICENSE",
                        }
                    ],
                    "attributions": [
                        {
                            "name": "Chinese Open Wordnet",
                            "url": "https://bond-lab.github.io/cow/",
                        },
                        {
                            "name": "Open Multilingual Wordnet",
                            "url": "https://omwn.org/",
                        },
                    ],
                    "counts": asdict(omw_cmn.counts),
                    "extraction_note": (
                        "Attach only Chinese lemmas whose synset ILI exactly equals the "
                        "OEWN sense synset ILI; retain raw values and normalize "
                        "+的/+地 for display."
                    ),
                },
            ],
            "modifications": _MODIFICATIONS,
            "license_files": [
                "licenses/oewn-2025.txt",
                "licenses/omw-cmn-2.0.txt",
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
                _write_zip_bytes(package, "licenses/omw-cmn-2.0.txt", _omw_cmn_license_notice())
            os.replace(temporary, output)
        finally:
            temporary.unlink(missing_ok=True)


def _align_translations(
    oewn: ParsedDictionarySource,
    omw_cmn: ParsedChineseSource,
) -> tuple[SenseTranslation, ...]:
    by_ili: defaultdict[str, list[ChineseLemma]] = defaultdict(list)
    for lemma in omw_cmn.lemmas:
        by_ili[lemma.synset_ili].append(lemma)
    translations: list[SenseTranslation] = []
    for entry in oewn.entries:
        if entry.synset_ili is None:
            continue
        seen_display: set[str] = set()
        sense_order = 0
        for lemma in by_ili.get(entry.synset_ili, []):
            if lemma.display_lemma in seen_display:
                continue
            seen_display.add(lemma.display_lemma)
            translations.append(
                SenseTranslation(
                    sense_id=entry.sense_id,
                    source_sense_id=lemma.source_sense_id,
                    raw_lemma=lemma.raw_lemma,
                    display_lemma=lemma.display_lemma,
                    source_id=lemma.source_id,
                    order=sense_order,
                )
            )
            sense_order += 1
    return tuple(translations)


def _entry_row(entry: DictionaryEntry) -> tuple[object, ...]:
    return (
        entry.headword,
        normalize(entry.headword),
        entry.part_of_speech,
        entry.sense_id,
        entry.gloss_en,
        entry.pronunciation,
        entry.synset_ili,
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


def _translation_row(translation: SenseTranslation) -> tuple[object, ...]:
    return (
        translation.sense_id,
        translation.source_sense_id,
        translation.raw_lemma,
        translation.display_lemma,
        translation.source_id,
        translation.order,
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


def _omw_cmn_license_notice() -> bytes:
    return b"""Copyright: 2013, 2014 Francis Bond, Shan Wang

Chinese Open WordNet

This software and database is being provided to you, the LICENSEE
under the following license.  By obtaining, using and/or copying this
software and database, you agree that you have read, understood, and
will comply with these terms and conditions:

Permission to use, copy, modify and distribute this software and
database and its documentation for any purpose and without fee or
royalty is hereby granted, provided that you agree to comply with the
following copyright notice and statements, including the disclaimer,
and that the same appear on ALL copies of the software, database and
documentation, including modifications that you make for internal use
or for distribution.

Chinese Open Wordnet Copyright 2013,2014 by Francis Bond and Shan
Wang.  All rights reserved.

THIS SOFTWARE AND DATABASE IS PROVIDED "AS IS" AND WE MAKE NO
REPRESENTATIONS OR WARRANTIES, EXPRESS OR IMPLIED.  BY WAY OF EXAMPLE,
BUT NOT LIMITATION, WE MAKE NO REPRESENTATIONS OR WARRANTIES OF
MERCHANTABILITY OR FITNESS FOR ANY PARTICULAR PURPOSE OR THAT THE USE
OF THE LICENSED SOFTWARE, DATABASE OR DOCUMENTATION WILL NOT INFRINGE
ANY THIRD PARTY PATENTS, COPYRIGHTS, TRADEMARKS OR OTHER RIGHTS.

Title to copyright in this software, database and any associated
documentation shall at all times remain with the copyright holders and
LICENSEE agrees to preserve same.
"""
