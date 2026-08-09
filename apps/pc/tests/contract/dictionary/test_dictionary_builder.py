from __future__ import annotations

import gzip
import hashlib
import json
import sqlite3
import tarfile
from pathlib import Path
from zipfile import ZipFile

import pytest

from engirdle_pc.modules.dictionary_builder.public import (
    DictionaryBuilder,
    DictionaryBuildRequest,
    DictionaryPublisher,
)
from engirdle_pc.modules.dictionary_builder.sources import (
    OewnLmfSource,
    OmwCmnLmfSource,
)
from engirdle_pc.shared.infrastructure.workspace import Workspace


def test_builder_aligns_ordered_chinese_lemmas_to_oewn_senses_by_ili(
    tmp_path: Path,
) -> None:
    oewn = _write_oewn_fixture(tmp_path)
    omw_cmn = _write_omw_cmn_fixture(tmp_path)
    first = tmp_path / "first.dictpack"
    second = tmp_path / "second.dictpack"
    request = DictionaryBuildRequest(
        oewn_archive=oewn,
        omw_cmn_archive=omw_cmn,
        output=first,
        revision=2,
        generated_at="2026-08-09T00:00:00Z",
    )

    artifact = _fixture_builder(oewn, omw_cmn).build(request)
    _fixture_builder(oewn, omw_cmn).build(
        DictionaryBuildRequest(
            oewn_archive=oewn,
            omw_cmn_archive=omw_cmn,
            output=second,
            revision=2,
            generated_at="2026-08-09T00:00:00Z",
        )
    )

    assert artifact.dictionary_id == "engirdle-en-zh"
    assert artifact.revision == 2
    assert artifact.sha256 == _sha256(first)
    assert first.read_bytes() == second.read_bytes()
    assert [summary.source_id for summary in artifact.sources] == [
        "oewn-2025",
        "omw-cmn:2.0",
    ]
    assert artifact.sources[0].counts.original_headwords == 5
    assert artifact.sources[0].counts.final_headwords == 4
    assert artifact.sources[1].counts.original_headwords == 4
    assert artifact.sources[1].counts.final_headwords == 3

    with ZipFile(first) as package:
        assert set(package.namelist()) == {
            "manifest.json",
            "dictionary.db",
            "licenses/oewn-2025.txt",
            "licenses/omw-cmn-2.0.txt",
        }
        manifest = json.loads(package.read("manifest.json"))
        assert manifest["format_version"] == "2.0"
        assert manifest["schema_version"] == 2
        assert [source["source_id"] for source in manifest["sources"]] == [
            "oewn-2025",
            "omw-cmn:2.0",
        ]
        assert manifest["sources"][1]["input"]["sha256"] == _sha256(omw_cmn)
        database = tmp_path / "dictionary.db"
        database.write_bytes(package.read("dictionary.db"))

    with sqlite3.connect(database) as connection:
        assert connection.execute("SELECT COUNT(*) FROM entries").fetchone() == (5,)
        assert connection.execute(
            "SELECT DISTINCT source_id FROM entries"
        ).fetchall() == [("oewn-2025",)]
        assert connection.execute(
            "SELECT raw_lemma, display_lemma, source_sense_id, source_id, ord "
            "FROM sense_translations WHERE sense_id = 'oewn-2025/oewn-mend-v-1' "
            "ORDER BY ord"
        ).fetchall() == [
            (
                "修理",
                "修理",
                "omw-cmn:2.0/omw-cmn-repair-1",
                "omw-cmn:2.0",
                0,
            ),
            (
                "修补+的",
                "修补的",
                "omw-cmn:2.0/omw-cmn-mended-1",
                "omw-cmn:2.0",
                1,
            ),
        ]
        assert connection.execute(
            "SELECT COUNT(*) FROM sense_translations "
            "WHERE sense_id = 'oewn-2025/oewn-mend-n-1'"
        ).fetchone() == (0,)
        assert connection.execute(
            "SELECT lemma FROM forms WHERE normalized_form = 'went'"
        ).fetchall() == [("go",)]
        assert connection.execute("PRAGMA quick_check").fetchone() == ("ok",)


def test_publisher_keeps_dictionary_revisions_immutable(tmp_path: Path) -> None:
    oewn = _write_oewn_fixture(tmp_path)
    omw_cmn = _write_omw_cmn_fixture(tmp_path)
    artifact = _fixture_builder(oewn, omw_cmn).build(
        DictionaryBuildRequest(
            oewn_archive=oewn,
            omw_cmn_archive=omw_cmn,
            output=tmp_path / "built.dictpack",
            revision=2,
            generated_at="2026-08-09T00:00:00Z",
        )
    )
    workspace = Workspace(tmp_path / "workspace")
    workspace.initialize()

    entry = DictionaryPublisher(workspace).publish(artifact)

    assert entry.format_version == "2.0"
    assert entry.schema_version == 2
    published = workspace.public_dir / entry.url.removeprefix("/")
    assert published.read_bytes() == artifact.path.read_bytes()

    different = _fixture_builder(oewn, omw_cmn).build(
        DictionaryBuildRequest(
            oewn_archive=oewn,
            omw_cmn_archive=omw_cmn,
            output=tmp_path / "different.dictpack",
            revision=2,
            generated_at="2026-08-09T01:00:00Z",
        )
    )
    with pytest.raises(ValueError, match="immutable dictionary revision"):
        DictionaryPublisher(workspace).publish(different)


def test_default_builder_rejects_untrusted_snapshots(tmp_path: Path) -> None:
    oewn = _write_oewn_fixture(tmp_path)
    omw_cmn = _write_omw_cmn_fixture(tmp_path)

    with pytest.raises(ValueError, match="snapshot sha256"):
        DictionaryBuilder().build(
            DictionaryBuildRequest(
                oewn_archive=oewn,
                omw_cmn_archive=omw_cmn,
                output=tmp_path / "untrusted.dictpack",
                revision=2,
                generated_at="2026-08-09T00:00:00Z",
            )
        )


def _write_oewn_fixture(root: Path) -> Path:
    path = root / "english-wordnet-2025.xml.gz"
    payload = """<?xml version="1.0" encoding="UTF-8"?>
<LexicalResource xmlns="http://globalwordnet.github.io/schemas/WN-LMF-1.3">
  <Lexicon id="oewn" label="Open English WordNet" language="en"
           version="2025" license="https://creativecommons.org/licenses/by/4.0">
    <LexicalEntry id="oewn-mend-v">
      <Lemma writtenForm="mend" partOfSpeech="v" />
      <Form writtenForm="mended" />
      <Sense id="oewn-mend-v-1" synset="oewn-0001-v" />
    </LexicalEntry>
    <LexicalEntry id="oewn-take-off-v">
      <Lemma writtenForm="take off" partOfSpeech="v" />
      <Sense id="oewn-take-off-v-1" synset="oewn-0002-v" />
    </LexicalEntry>
    <LexicalEntry id="oewn-mend-n">
      <Lemma writtenForm="mend" partOfSpeech="n" />
      <Sense id="oewn-mend-n-1" synset="oewn-0003-n" />
    </LexicalEntry>
    <LexicalEntry id="oewn-go-v">
      <Lemma writtenForm="go" partOfSpeech="v" />
      <Sense id="oewn-go-v-1" synset="oewn-0004-v" />
    </LexicalEntry>
    <LexicalEntry id="oewn-stop-v">
      <Lemma writtenForm="stop" partOfSpeech="v" />
      <Form writtenForm="stopped" />
      <Form writtenForm="stopping" />
      <Sense id="oewn-stop-v-1" synset="oewn-0005-v" />
    </LexicalEntry>
    <Synset id="oewn-0001-v" ili="i100" partOfSpeech="v">
      <Definition>to repair something</Definition>
    </Synset>
    <Synset id="oewn-0002-v" ili="i102" partOfSpeech="v">
      <Definition>to leave the ground</Definition>
    </Synset>
    <Synset id="oewn-0003-n" ili="i101" partOfSpeech="n">
      <Definition>a repaired place</Definition>
    </Synset>
    <Synset id="oewn-0004-v" ili="i103" partOfSpeech="v">
      <Definition>to move or travel</Definition>
    </Synset>
    <Synset id="oewn-0005-v" ili="i104" partOfSpeech="v">
      <Definition>to cease moving</Definition>
    </Synset>
  </Lexicon>
</LexicalResource>
"""
    with path.open("wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as stream:
        stream.write(payload.encode())
    return path


def _write_omw_cmn_fixture(root: Path) -> Path:
    path = root / "omw-cmn-2.0.tar.xz"
    xml = """<?xml version="1.0" encoding="UTF-8"?>
<LexicalResource>
  <Lexicon id="omw-cmn" label="Chinese Open Wordnet" language="cmn-Hans"
           version="2.0" license="wordnet">
    <Requires ref="omw-en" version="2.0" />
    <LexicalEntry id="omw-cmn-repair-v">
      <Lemma writtenForm="修理" partOfSpeech="v" />
      <Sense id="omw-cmn-repair-1" synset="omw-cmn-0001-v" />
    </LexicalEntry>
    <LexicalEntry id="omw-cmn-mended-a">
      <Lemma writtenForm="修补+的" partOfSpeech="a" />
      <Sense id="omw-cmn-mended-1" synset="omw-cmn-0001-v" />
    </LexicalEntry>
    <LexicalEntry id="omw-cmn-mended-duplicate-a">
      <Lemma writtenForm="修补的" partOfSpeech="a" />
      <Sense id="omw-cmn-mended-duplicate-1" synset="omw-cmn-0001-v" />
    </LexicalEntry>
    <LexicalEntry id="omw-cmn-launch-v">
      <Lemma writtenForm="起飞" partOfSpeech="v" />
      <Sense id="omw-cmn-launch-1" synset="omw-cmn-0002-v" />
    </LexicalEntry>
    <Synset id="omw-cmn-0001-v" ili="i100" partOfSpeech="v" />
    <Synset id="omw-cmn-0002-v" ili="i102" partOfSpeech="v" />
  </Lexicon>
</LexicalResource>
""".encode()
    xml_source = root / "omw-cmn.xml"
    license_source = root / "LICENSE"
    xml_source.write_bytes(xml)
    license_source.write_text(
        "Chinese Open Wordnet Copyright 2013,2014 by Francis Bond and Shan Wang.\n",
        encoding="utf-8",
    )
    with tarfile.open(path, "w:xz", format=tarfile.PAX_FORMAT) as archive:
        for source, name in (
            (xml_source, "omw-cmn/omw-cmn.xml"),
            (license_source, "omw-cmn/LICENSE"),
        ):
            info = archive.gettarinfo(source, arcname=name)
            info.mtime = 0
            with source.open("rb") as stream:
                archive.addfile(info, stream)
    return path


def _fixture_builder(oewn: Path, omw_cmn: Path) -> DictionaryBuilder:
    return DictionaryBuilder(
        oewn=OewnLmfSource(expected_sha256=_sha256(oewn)),
        omw_cmn=OmwCmnLmfSource(expected_sha256=_sha256(omw_cmn)),
    )


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()
