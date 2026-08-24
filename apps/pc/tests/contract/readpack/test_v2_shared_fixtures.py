"""Shared Readpack v2 fixture tests.

A full v2 validator ships with the mobile import work (design phase 2);
until then this structural checker keeps the frozen v2 contract honest from
the PC side: container path-set equality, JSON Schema conformance, payload
integrity, and the semantic core (identity/structure-hash binding, translation
coverage, narration coverage and ranges, derivative-consistent attribution).
"""

from __future__ import annotations

import json
import zipfile
from pathlib import Path
from typing import Any

import pytest
from jsonschema import Draft202012Validator, FormatChecker

from engirdle_pc.bootstrap.config import Settings

V2 = "readpack/v2"


class V2StructuralError(ValueError):
    """Raised when a v2 package violates the frozen contract."""


def _schema(contracts: Path, name: str) -> Draft202012Validator:
    schema = json.loads((contracts / V2 / "schema" / f"{name}.schema.json").read_text("utf-8"))
    return Draft202012Validator(schema, format_checker=FormatChecker())


def _check_schema(contracts: Path, name: str, payload: dict[str, Any], where: str) -> None:
    errors = sorted(_schema(contracts, name).iter_errors(payload), key=str)
    if errors:
        raise V2StructuralError(f"{where}: schema violation: {errors[0].message}")


def _hash(data: bytes) -> str:
    import hashlib

    return hashlib.sha256(data).hexdigest()


def validate_payloads(
    contracts: Path, manifest: dict[str, Any], payloads: dict[str, bytes]
) -> None:
    """Structural + integrity + semantic-core validation of one v2 package."""
    _check_schema(contracts, "manifest", manifest, "manifest.json")
    # v2.0 defines no capabilities (COMPATIBILITY.md): an unknown token must
    # be rejected before anything else, like a v1.0 client rejects 1.1 packs.
    if manifest.get("required_capabilities"):
        raise V2StructuralError(
            "v2.0 defines no required_capabilities; unknown values must be "
            "rejected before import"
        )

    declared = {entry["path"] for entry in manifest["files"]}
    if "manifest.json" in declared:
        raise V2StructuralError("manifest must not declare itself in files")
    missing = declared - set(payloads)
    extra = set(payloads) - declared
    if missing:
        raise V2StructuralError(f"declared files missing from package: {sorted(missing)}")
    if extra:
        raise V2StructuralError(f"undeclared files in package: {sorted(extra)}")

    for entry in manifest["files"]:
        data = payloads[entry["path"]]
        if len(data) != entry["size"] or _hash(data) != entry["sha256"]:
            raise V2StructuralError(f"{entry['path']}: size or hash mismatch")

    article = _json(payloads, "article.json")
    _check_schema(contracts, "article", article, "article.json")
    attribution = _json(payloads, "attribution.json")
    _check_schema(contracts, "attribution", attribution, "attribution.json")

    if manifest["article"]["id"] != article["article_id"]:
        raise V2StructuralError("manifest/article article id mismatch")
    if manifest["article"]["revision"] != article["revision"]:
        raise V2StructuralError("manifest/article revision mismatch")
    if attribution["article"]["id"] != article["article_id"]:
        raise V2StructuralError("attribution/article article id mismatch")
    if manifest["content"]["structure_sha256"] != article["structure_sha256"]:
        raise V2StructuralError("content structure hash mismatch")

    text_sentence_ids: list[str] = []
    table_block_ids: list[str] = []
    table_cell_ids: dict[str, list[str]] = {}
    for block in article["blocks"]:
        if block["kind"] in ("paragraph", "heading", "list_item", "quote"):
            for sentence in block["sentences"]:
                if "translation_zh" in sentence or "audio_start_sample" in sentence:
                    raise V2StructuralError("v2 article must not carry derived fields")
                text_sentence_ids.append(sentence["sentence_id"])
            for sentence in block["sentences"]:
                runs_text = "".join(run["text"] for run in sentence["runs"])
                if runs_text != sentence["text"]:
                    raise V2StructuralError(
                        f"{sentence['sentence_id']}: runs do not concatenate to text"
                    )
        elif block["kind"] == "table":
            if "translation_zh" in block:
                raise V2StructuralError("v2 table must not carry translation_zh")
            table_block_ids.append(block["block_id"])
            table_cell_ids[block["block_id"]] = [
                cell["cell_id"]
                for cell in [
                    *block["header"],
                    *(cell for row in block["rows"] for cell in row),
                ]
            ]

    derivatives = manifest["derivatives"]
    translation_paths = [item["path"] for item in derivatives["translations"]]
    narration = derivatives["narration"]

    for path in translation_paths:
        translation = _json(payloads, path)
        _check_schema(contracts, "translation", translation, path)
        if translation["article"]["id"] != article["article_id"]:
            raise V2StructuralError(f"{path}: article id mismatch")
        if translation["structure_sha256"] != article["structure_sha256"]:
            raise V2StructuralError(f"{path}: structure hash mismatch")
        if [item["sentence_id"] for item in translation["sentences"]] != (text_sentence_ids):
            raise V2StructuralError(f"{path}: sentence coverage mismatch")
        if [item["block_id"] for item in translation["tables"]] != table_block_ids:
            raise V2StructuralError(f"{path}: table coverage mismatch")
        for table in translation["tables"]:
            if [cell["cell_id"] for cell in table["cells"]] != (table_cell_ids[table["block_id"]]):
                raise V2StructuralError(f"{path}: cell coverage mismatch for {table['block_id']}")

    audio_declared = any(entry["path"] == "audio/article.m4a" for entry in manifest["files"])
    if audio_declared and narration is None:
        raise V2StructuralError("audio file declared without a narration derivative")

    if narration is not None:
        narration_payload = _json(payloads, narration["path"])
        _check_schema(contracts, "narration", narration_payload, narration["path"])
        if narration_payload["article"]["id"] != article["article_id"]:
            raise V2StructuralError("narration: article id mismatch")
        if narration_payload["structure_sha256"] != article["structure_sha256"]:
            raise V2StructuralError("narration: structure hash mismatch")
        ranges = narration_payload["sentences"]
        if [item["sentence_id"] for item in ranges] != text_sentence_ids:
            raise V2StructuralError("narration: sentence coverage mismatch")
        audio = narration_payload["audio"]
        total_samples = audio["duration_ms"] * audio["sample_rate_hz"] // 1000
        previous_end = 0
        for item in ranges:
            if item["audio_start_sample"] >= item["audio_end_sample"]:
                raise V2StructuralError(f"{item['sentence_id']}: empty narration range")
            if item["audio_start_sample"] < previous_end:
                raise V2StructuralError(f"{item['sentence_id']}: narration ranges overlap")
            if item["audio_end_sample"] > total_samples:
                raise V2StructuralError(f"{item['sentence_id']}: narration range exceeds audio")
            expected_start_ms = item["audio_start_sample"] * 1000 // audio["sample_rate_hz"]
            expected_end_ms = -(-item["audio_end_sample"] * 1000 // audio["sample_rate_hz"])
            if (
                item["audio_start_ms"] != expected_start_ms
                or item["audio_end_ms"] != expected_end_ms
            ):
                raise V2StructuralError(
                    f"{item['sentence_id']}: millisecond bounds not derived from sample bounds"
                )
            previous_end = item["audio_end_sample"]

    attribution_kinds = {resource["kind"] for resource in attribution["resources"]}
    if translation_paths and "translation_service" not in attribution_kinds:
        raise V2StructuralError("translation derivative without a translation_service attribution")
    if (
        narration is not None
        and not {
            "tts_model",
            "voice_profile",
        }
        <= attribution_kinds
    ):
        raise V2StructuralError("narration derivative without tts/voice attribution")


def _json(payloads: dict[str, bytes], path: str) -> dict[str, Any]:
    if path not in payloads:
        raise V2StructuralError(f"declared file missing from package: {path}")
    return json.loads(payloads[path].decode("utf-8"))


def _validate_zip(contracts: Path, fixture: Path) -> None:
    with zipfile.ZipFile(fixture) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise V2StructuralError("duplicate ZIP entry")
        for name in names:
            if name.endswith("/"):
                raise V2StructuralError(f"directory entry: {name}")
        if "manifest.json" not in names:
            raise V2StructuralError("manifest.json missing")
        manifest = json.loads(archive.read("manifest.json").decode("utf-8"))
        payloads = {name: archive.read(name) for name in names if name != "manifest.json"}
    validate_payloads(contracts, manifest, payloads)


@pytest.mark.parametrize(
    "fixture_name",
    ["source-only.readpack", "translated.readpack", "narrated.readpack", "full.readpack"],
)
def test_v2_valid_fixtures_pass_structural_validation(fixture_name: str) -> None:
    contracts = Settings().contracts_dir

    _validate_zip(contracts, contracts / V2 / "fixtures/valid" / fixture_name)


@pytest.mark.parametrize(
    ("fixture_name", "reason"),
    [
        ("undeclared-extra-file.readpack", "undeclared files"),
        ("missing-base-file.readpack", "declared files missing"),
        ("translation-sentence-missing.readpack", "sentence coverage mismatch"),
        ("translation-structure-mismatch.readpack", "structure hash mismatch"),
        ("translation-cell-missing.readpack", "cell coverage mismatch"),
        ("narration-range-empty.readpack", "empty narration range"),
        ("audio-without-narration.readpack", "without a narration derivative"),
        ("wrong-hash.readpack", "size or hash mismatch"),
        ("duplicate-path.readpack", "duplicate ZIP entry"),
        ("unsupported-major.readpack", "schema violation"),
        ("unknown-capability.readpack", "no required_capabilities"),
    ],
)
def test_v2_invalid_fixtures_are_rejected(fixture_name: str, reason: str) -> None:
    contracts = Settings().contracts_dir

    with pytest.raises(V2StructuralError, match=reason):
        _validate_zip(contracts, contracts / V2 / "fixtures/invalid" / fixture_name)


@pytest.mark.parametrize("example", ["minimal-source", "full"])
def test_v2_examples_pass_structural_validation(example: str) -> None:
    contracts = Settings().contracts_dir
    directory = contracts / V2 / "examples" / example

    manifest = json.loads((directory / "manifest.json").read_text("utf-8"))
    payloads: dict[str, bytes] = {}
    for path in directory.rglob("*"):
        if path.is_file() and path.name != "manifest.json":
            payloads[path.relative_to(directory).as_posix()] = path.read_bytes()

    validate_payloads(contracts, manifest, payloads)
