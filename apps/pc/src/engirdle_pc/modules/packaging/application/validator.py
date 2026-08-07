from __future__ import annotations

import json
import stat
from pathlib import Path, PurePosixPath
from typing import Any, ClassVar, cast
from zipfile import ZipFile

from jsonschema import Draft202012Validator, FormatChecker  # type: ignore[import-untyped]

from engirdle_pc.shared.infrastructure.hashing import sha256_bytes


class InvalidReadpack(ValueError):
    """A readpack violates its container, schema, integrity, or semantic contract."""


class ReadpackValidator:
    _ALLOWED_PATHS: ClassVar[set[str]] = {
        "manifest.json",
        "article.json",
        "attribution.json",
        "audio/article.m4a",
    }

    def __init__(self, contracts_dir: Path) -> None:
        schema_dir = contracts_dir / "readpack" / "v1" / "schema"
        self._schemas = {
            "manifest.json": _read_json(schema_dir / "manifest.schema.json"),
            "article.json": _read_json(schema_dir / "article.schema.json"),
            "attribution.json": _read_json(schema_dir / "attribution.schema.json"),
        }

    def validate(self, package_path: Path) -> None:
        with ZipFile(package_path) as archive:
            names = [entry.filename for entry in archive.infolist()]
            if len(names) != len(set(names)):
                raise InvalidReadpack("duplicate ZIP path")
            if set(names) != self._ALLOWED_PATHS:
                raise InvalidReadpack("readpack has a missing or unapproved path")
            for entry in archive.infolist():
                path = PurePosixPath(entry.filename)
                if path.is_absolute() or ".." in path.parts or not entry.filename:
                    raise InvalidReadpack("unsafe ZIP path")
                mode = entry.external_attr >> 16
                file_type = stat.S_IFMT(mode)
                if file_type and file_type != stat.S_IFREG:
                    raise InvalidReadpack("non-regular ZIP entry")
                if entry.file_size > 1024 * 1024 * 1024:
                    raise InvalidReadpack("ZIP entry exceeds the v1 size limit")

            raw_payloads = {
                name: archive.read(name)
                for name in ("manifest.json", "article.json", "attribution.json")
            }
            payloads = {
                name: _decode_json(content, name) for name, content in raw_payloads.items()
            }
            for name, payload in payloads.items():
                validator = Draft202012Validator(
                    self._schemas[name], format_checker=FormatChecker()
                )
                errors = sorted(validator.iter_errors(payload), key=lambda error: list(error.path))
                if errors:
                    raise InvalidReadpack(f"{name} schema error: {errors[0].message}")

            manifest = payloads["manifest.json"]
            article = payloads["article.json"]
            attribution = payloads["attribution.json"]
            if not str(manifest["format_version"]).startswith("1."):
                raise InvalidReadpack("unsupported readpack major version")
            expected_payloads = {
                "article.json": raw_payloads["article.json"],
                "attribution.json": raw_payloads["attribution.json"],
                "audio/article.m4a": archive.read("audio/article.m4a"),
            }
            for file_entry in manifest["files"]:
                content = expected_payloads[file_entry["path"]]
                if file_entry["size"] != len(content):
                    raise InvalidReadpack(f"size mismatch for {file_entry['path']}")
                if file_entry["sha256"] != sha256_bytes(content):
                    raise InvalidReadpack(f"hash mismatch for {file_entry['path']}")

            identity = manifest["article"]
            if identity["id"] != article["article_id"] or identity["revision"] != article[
                "revision"
            ]:
                raise InvalidReadpack("manifest and article identity mismatch")
            if identity["id"] != attribution["article"]["id"] or identity[
                "revision"
            ] != attribution["article"]["revision"]:
                raise InvalidReadpack("manifest and attribution identity mismatch")
            _validate_article_semantics(article, manifest["audio"])


def _validate_article_semantics(
    article: dict[str, Any], audio: dict[str, Any]
) -> None:
    block_ids: set[str] = set()
    sentence_ids: set[str] = set()
    previous_end = 0
    max_sample = audio["duration_ms"] * audio["sample_rate_hz"] // 1000 + 1
    for block_order, block in enumerate(article["blocks"]):
        if block["order"] != block_order or block["block_id"] in block_ids:
            raise InvalidReadpack("block IDs must be unique and orders contiguous")
        block_ids.add(block["block_id"])
        for sentence_order, sentence in enumerate(block["sentences"]):
            if sentence["order"] != sentence_order or sentence["sentence_id"] in sentence_ids:
                raise InvalidReadpack("sentence IDs must be unique and orders contiguous")
            sentence_ids.add(sentence["sentence_id"])
            required = (
                "translation_zh",
                "audio_start_sample",
                "audio_end_sample",
                "audio_start_ms",
                "audio_end_ms",
            )
            if any(field not in sentence for field in required):
                raise InvalidReadpack("every published sentence needs translation and audio")
            if not sentence["translation_zh"].strip():
                raise InvalidReadpack("published translations must not be empty")
            if not (
                previous_end <= sentence["audio_start_sample"]
                < sentence["audio_end_sample"]
                <= max_sample
            ):
                raise InvalidReadpack("sentence audio ranges must be ordered and bounded")
            previous_end = sentence["audio_end_sample"]


def _read_json(path: Path) -> dict[str, Any]:
    return cast(dict[str, Any], json.loads(path.read_text(encoding="utf-8")))


def _decode_json(content: bytes, name: str) -> dict[str, Any]:
    if content.startswith(b"\xef\xbb\xbf"):
        raise InvalidReadpack(f"{name} must not contain a BOM")
    try:
        return cast(dict[str, Any], json.loads(content.decode("utf-8")))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise InvalidReadpack(f"invalid JSON in {name}") from error
