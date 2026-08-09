from __future__ import annotations

import gzip
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
from engirdle_pc.shared.infrastructure.workspace import Workspace


def test_builder_emits_deterministic_versioned_bilingual_dictpack(
    tmp_path: Path,
) -> None:
    oewn = _write_oewn_fixture(tmp_path)
    freedict = _write_freedict_fixture(tmp_path)
    first = tmp_path / "first.dictpack"
    second = tmp_path / "second.dictpack"
    request = DictionaryBuildRequest(
        oewn_archive=oewn,
        freedict_archive=freedict,
        output=first,
        revision=1,
        generated_at="2026-08-09T00:00:00Z",
    )

    artifact = DictionaryBuilder().build(request)
    DictionaryBuilder().build(
        DictionaryBuildRequest(
            oewn_archive=oewn,
            freedict_archive=freedict,
            output=second,
            revision=1,
            generated_at="2026-08-09T00:00:00Z",
        )
    )

    assert artifact.dictionary_id == "engirdle-en-zh"
    assert artifact.revision == 1
    assert artifact.sha256 == _sha256(first)
    assert first.read_bytes() == second.read_bytes()

    with ZipFile(first) as package:
        assert set(package.namelist()) == {
            "manifest.json",
            "dictionary.db",
            "licenses/oewn-2025.txt",
            "licenses/freedict-eng-zho-2025.11.23.txt",
        }
        manifest = json.loads(package.read("manifest.json"))
        assert manifest["format_version"] == "1.0"
        assert manifest["dictionary_id"] == "engirdle-en-zh"
        assert manifest["revision"] == 1
        assert manifest["schema_version"] == 1
        assert [source["source_id"] for source in manifest["sources"]] == [
            "oewn-2025",
            "freedict-eng-zho-2025.11.23",
        ]
        assert manifest["sources"][0]["counts"] == {
            "original_headwords": 4,
            "filtered_headwords": 0,
            "final_headwords": 3,
        }
        assert manifest["sources"][1]["counts"] == {
            "original_headwords": 2,
            "filtered_headwords": 0,
            "final_headwords": 2,
        }
        assert manifest["database"]["sha256"] == _sha256_bytes(package.read("dictionary.db"))
        assert manifest["database"]["size"] == len(package.read("dictionary.db"))
        assert manifest["modifications"]

        database = tmp_path / "dictionary.db"
        database.write_bytes(package.read("dictionary.db"))

    with sqlite3.connect(database) as connection:
        entries = connection.execute(
            "SELECT headword, pos, gloss_en, gloss_zh, source_id "
            "FROM entries WHERE normalized_headword = 'mend' "
            "ORDER BY source_rank, pos_rank, ord"
        ).fetchall()
        assert entries == [
            ("mend", "noun", "a repaired place", None, "oewn-2025"),
            ("mend", "verb", "to repair something", None, "oewn-2025"),
            (
                "mend",
                "verb",
                None,
                "修理; 修补",
                "freedict-eng-zho-2025.11.23",
            ),
        ]
        assert connection.execute(
            "SELECT lemma, source_id FROM forms WHERE normalized_form = 'mended' "
            "ORDER BY source_rank, ord"
        ).fetchall() == [("mend", "oewn-2025")]
        assert connection.execute(
            "SELECT lemma FROM forms WHERE normalized_form = 'went'"
        ).fetchall() == [("go",)]
        assert (
            connection.execute("SELECT lemma FROM forms WHERE normalized_form = 'goed'").fetchall()
            == []
        )
        assert connection.execute(
            "SELECT gloss_en FROM entries WHERE normalized_headword = 'take off'"
        ).fetchone() == ("to leave the ground",)
        assert connection.execute(
            "SELECT pronunciation FROM entries "
            "WHERE source_id = 'freedict-eng-zho-2025.11.23' "
            "AND normalized_headword = 'mend'"
        ).fetchone() == ("mɛnd",)
        assert connection.execute(
            "SELECT COUNT(*) FROM entries WHERE normalized_headword = 'not-a-word'"
        ).fetchone() == (0,)
        assert connection.execute("PRAGMA quick_check").fetchone() == ("ok",)


def test_publisher_copies_an_immutable_package_and_records_catalog_metadata(
    tmp_path: Path,
) -> None:
    artifact = DictionaryBuilder().build(
        DictionaryBuildRequest(
            oewn_archive=_write_oewn_fixture(tmp_path),
            freedict_archive=_write_freedict_fixture(tmp_path),
            output=tmp_path / "built.dictpack",
            revision=1,
            generated_at="2026-08-09T00:00:00Z",
        )
    )
    workspace = Workspace(tmp_path / "workspace")
    workspace.initialize()

    entry = DictionaryPublisher(workspace).publish(artifact)

    assert entry.url.startswith("/dictionaries/engirdle-en-zh-r1-")
    assert entry.url.endswith(".dictpack")
    published = workspace.public_dir / entry.url.removeprefix("/")
    assert published.read_bytes() == artifact.path.read_bytes()
    sidecar = json.loads((workspace.public_dir / "dictionary.json").read_text())
    assert sidecar["dictionary_id"] == "engirdle-en-zh"
    assert sidecar["sha256"] == artifact.sha256

    different = DictionaryBuilder().build(
        DictionaryBuildRequest(
            oewn_archive=tmp_path / "english-wordnet-2025.xml.gz",
            freedict_archive=tmp_path / "freedict-eng-zho-2025.11.23.src.tar.xz",
            output=tmp_path / "different.dictpack",
            revision=1,
            generated_at="2026-08-09T01:00:00Z",
        )
    )
    with pytest.raises(ValueError, match="immutable dictionary revision"):
        DictionaryPublisher(workspace).publish(different)
    assert (
        json.loads((workspace.public_dir / "dictionary.json").read_text())["sha256"]
        == artifact.sha256
    )


def _write_oewn_fixture(root: Path) -> Path:
    path = root / "english-wordnet-2025.xml.gz"
    payload = """<?xml version="1.0" encoding="UTF-8"?>
<LexicalResource xmlns="http://globalwordnet.github.io/schemas/WN-LMF-1.3">
  <Lexicon id="oewn" label="Open English WordNet" language="en">
    <LexicalEntry id="oewn-mend-v">
      <Lemma writtenForm="mend" partOfSpeech="v" />
      <WordForm writtenForm="mended" />
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
    <Synset id="oewn-0001-v" partOfSpeech="v">
      <Definition>to repair something</Definition>
    </Synset>
    <Synset id="oewn-0002-v" partOfSpeech="v">
      <Definition>to leave the ground</Definition>
    </Synset>
    <Synset id="oewn-0003-n" partOfSpeech="n">
      <Definition>a repaired place</Definition>
    </Synset>
    <Synset id="oewn-0004-v" partOfSpeech="v">
      <Definition>to move or travel</Definition>
    </Synset>
  </Lexicon>
</LexicalResource>
"""
    with path.open("wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as stream:
        stream.write(payload.encode())
    return path


def _write_freedict_fixture(root: Path) -> Path:
    path = root / "freedict-eng-zho-2025.11.23.src.tar.xz"
    tei = """<?xml version="1.0" encoding="UTF-8"?>
<TEI xmlns="http://www.tei-c.org/ns/1.0">
  <text><body>
    <entry xml:id="mend-v">
      <form type="lemma"><orth>mend</orth><pron>mɛnd</pron></form>
      <gramGrp><pos>verb</pos></gramGrp>
      <sense xml:id="mend-v-1">
        <cit type="trans"><quote xml:lang="zh">修理</quote></cit>
        <cit type="trans"><quote xml:lang="zh">修补</quote></cit>
      </sense>
    </entry>
    <entry xml:id="bank-n">
      <form type="lemma"><orth>bank</orth></form>
      <gramGrp><pos>noun</pos></gramGrp>
      <sense xml:id="bank-n-1">
        <cit type="trans"><quote xml:lang="zh">银行</quote></cit>
      </sense>
    </entry>
  </body></text>
</TEI>
""".encode()
    source = root / "eng-zho.tei"
    source.write_bytes(tei)
    with tarfile.open(path, "w:xz", format=tarfile.PAX_FORMAT) as archive:
        info = archive.gettarinfo(source, arcname="freedict-eng-zho-2025.11.23/eng-zho.tei")
        info.mtime = 0
        with source.open("rb") as stream:
            archive.addfile(info, stream)
    return path


def _sha256(path: Path) -> str:
    return _sha256_bytes(path.read_bytes())


def _sha256_bytes(payload: bytes) -> str:
    import hashlib

    return hashlib.sha256(payload).hexdigest()
