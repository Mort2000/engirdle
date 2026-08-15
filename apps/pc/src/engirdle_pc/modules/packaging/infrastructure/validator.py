from __future__ import annotations

import json
import stat
from pathlib import Path, PurePosixPath
from typing import Any, ClassVar, cast
from zipfile import ZipFile

from jsonschema import Draft202012Validator, FormatChecker  # type: ignore[import-untyped]

from engirdle_pc.modules.content.public import DEFAULT_LIMITS
from engirdle_pc.modules.packaging.application.errors import InvalidReadpack
from engirdle_pc.shared.domain.hashing import sha256_bytes


class ReadpackValidator:
    _ALLOWED_PATHS: ClassVar[set[str]] = {
        "manifest.json",
        "article.json",
        "attribution.json",
        "audio/article.m4a",
    }
    # The only capabilities this validator understands (design §9.1/§9.3.9):
    # an unknown capability must be rejected before the package is trusted.
    _KNOWN_CAPABILITIES: ClassVar[set[str]] = {"markdown-blocks"}
    _V11_BLOCK_KINDS: ClassVar[set[str]] = {"heading", "table", "code", "divider"}
    _TEXT_KINDS: ClassVar[set[str]] = {"paragraph", "list_item", "quote", "heading"}
    # Known block-level fields grouped by the kinds that may carry them.
    # Anything in another kind's group is a payload the kind cannot have —
    # the block union must stay discriminated (unknown minor-version
    # extension fields are still allowed via additionalProperties).
    _KIND_FIELDS: ClassVar[dict[str, set[str]]] = {
        "paragraph": set(),
        "list_item": {"list_kind", "list_depth", "list_ordinal"},
        "quote": {"quote_depth"},
        "heading": {"level"},
        "table": {"alignments", "header", "rows", "translation_zh"},
        "code": {"code", "language"},
        "divider": set(),
    }
    _ALL_KIND_FIELDS: ClassVar[set[str]] = {
        "level",
        "list_kind",
        "list_depth",
        "list_ordinal",
        "quote_depth",
        "alignments",
        "header",
        "rows",
        "translation_zh",
        "code",
        "language",
        "sentences",
    }
    # Whole-package cap matches the catalog schema's package-size maximum so a
    # package that could never be published is rejected at build time rather
    # than only when the catalog is generated.
    _MAX_PACKAGE_BYTES: ClassVar[int] = 512 * 1024 * 1024

    def __init__(self, contracts_dir: Path) -> None:
        schema_dir = contracts_dir / "readpack" / "v1" / "schema"
        self._schemas = {
            "manifest.json": _read_json(schema_dir / "manifest.schema.json"),
            "article.json": _read_json(schema_dir / "article.schema.json"),
            "attribution.json": _read_json(schema_dir / "attribution.schema.json"),
        }

    def validate(self, package_path: Path) -> None:
        if package_path.stat().st_size > self._MAX_PACKAGE_BYTES:
            raise InvalidReadpack("readpack exceeds the v1 package size limit")
        with ZipFile(package_path) as archive:
            names = [entry.filename for entry in archive.infolist()]
            if len(names) != len(set(names)):
                raise InvalidReadpack("duplicate ZIP path")
            if set(names) != self._ALLOWED_PATHS:
                raise InvalidReadpack("readpack has a missing or unapproved path")
            for entry in archive.infolist():
                if entry.flag_bits & 0x1:
                    raise InvalidReadpack("encrypted ZIP entries are not supported")
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
                content = expected_payloads.get(file_entry["path"])
                if content is None:
                    raise InvalidReadpack(
                        f"manifest references unknown file path {file_entry['path']}"
                    )
                if file_entry["size"] != len(content):
                    raise InvalidReadpack(f"size mismatch for {file_entry['path']}")
                if file_entry["sha256"] != sha256_bytes(content):
                    raise InvalidReadpack(f"hash mismatch for {file_entry['path']}")

            if str(manifest["format_version"]) != str(article.get("format_version")):
                raise InvalidReadpack("manifest and article format versions disagree")
            manifest_capabilities = sorted(manifest.get("required_capabilities", []))
            article_capabilities = sorted(article.get("required_capabilities", []))
            if manifest_capabilities != article_capabilities:
                raise InvalidReadpack("manifest and article capabilities disagree")
            identity = manifest["article"]
            if identity["id"] != article["article_id"] or identity["revision"] != article[
                "revision"
            ]:
                raise InvalidReadpack("manifest and article identity mismatch")
            if identity["id"] != attribution["article"]["id"] or identity[
                "revision"
            ] != attribution["article"]["revision"]:
                raise InvalidReadpack("manifest and attribution identity mismatch")
            _validate_article_semantics(article, manifest["audio"], manifest)


def _validate_article_semantics(
    article: dict[str, Any],
    audio: dict[str, Any],
    manifest: dict[str, Any],
) -> None:
    """Shared v1.0/v1.1 semantic rules (design §9.3)."""
    version = str(article.get("format_version"))
    capabilities = set(manifest.get("required_capabilities", []))
    unknown = capabilities - ReadpackValidator._KNOWN_CAPABILITIES
    if unknown:
        raise InvalidReadpack(
            f"unknown required capability: {sorted(unknown)[0]}"
        )
    if version == "1.1":
        if "markdown-blocks" not in capabilities:
            raise InvalidReadpack("a 1.1 article must require the markdown-blocks capability")
    else:
        if capabilities:
            raise InvalidReadpack("a 1.0 package must not declare capabilities")
    block_ids: set[str] = set()
    sentence_ids: set[str] = set()
    cell_ids: set[str] = set()
    narratable_sentences = 0
    previous_end = 0
    max_sample = audio["duration_ms"] * audio["sample_rate_hz"] // 1000 + 1
    total_code_bytes = 0
    for block_order, block in enumerate(article["blocks"]):
        kind = block.get("kind")
        if block["order"] != block_order or block["block_id"] in block_ids:
            raise InvalidReadpack("block IDs must be unique and orders contiguous")
        block_ids.add(block["block_id"])
        if version != "1.1" and kind in ReadpackValidator._V11_BLOCK_KINDS:
            raise InvalidReadpack("a v1.0 package must not carry v1.1 block kinds")
        _reject_cross_kind_fields(kind, block)
        if kind in ReadpackValidator._TEXT_KINDS:
            _validate_text_block(
                block, version, sentence_ids, audio, max_sample, previous_end
            )
            previous_end = block["sentences"][-1]["audio_end_sample"]
            narratable_sentences += len(block["sentences"])
        elif kind == "table":
            _validate_table_block(block, version, cell_ids)
        elif kind == "code":
            _validate_code_block(block)
            total_code_bytes += len(str(block["code"]).encode("utf-8"))
        elif kind == "divider":
            continue
        else:
            raise InvalidReadpack(f"unknown block kind: {kind}")
    if narratable_sentences == 0:
        raise InvalidReadpack("the article needs at least one narratable sentence")
    # The document-level code budget shares the frozen contract values with
    # the content module and the mobile import (design §4.4).
    if total_code_bytes > DEFAULT_LIMITS.max_total_code_bytes:
        raise InvalidReadpack(
            f"total code bytes exceed {DEFAULT_LIMITS.max_total_code_bytes}"
        )


def _reject_cross_kind_fields(kind: str, block: dict[str, Any]) -> None:
    """A block may only carry the payload fields its kind defines (§5.1).

    Known cross-kind fields reject; unknown fields stay allowed so later
    1.x minors can extend the union without breaking this validator.
    """
    legal = ReadpackValidator._KIND_FIELDS.get(kind)
    if legal is None:
        return
    legal = set(legal) | {"block_id", "kind", "order"}
    if kind in ReadpackValidator._TEXT_KINDS:
        legal.add("sentences")
    for field in ReadpackValidator._ALL_KIND_FIELDS:
        if field not in legal and field in block:
            raise InvalidReadpack(
                f"{kind} blocks must not carry the {field} payload"
            )


def _validate_text_block(
    block: dict[str, Any],
    version: str,
    sentence_ids: set[str],
    audio: dict[str, Any],
    max_sample: int,
    previous_end: int,
) -> None:
    if "sentences" not in block or not block["sentences"]:
        raise InvalidReadpack("text blocks need at least one sentence")
    kind = block["kind"]
    if kind == "heading" and not 1 <= block.get("level", 0) <= 6:
        raise InvalidReadpack("heading blocks need a 1-6 level")
    # v1.1 list items carry their kind explicitly; a v1.0 list item has no
    # list payload and decodes to the bullet default (COMPATIBILITY.md).
    if (
        kind == "list_item"
        and version == "1.1"
        and block.get("list_kind") not in {"bullet", "ordered"}
    ):
        raise InvalidReadpack("list_item blocks need a list kind")
    if kind == "quote" and version == "1.1" and not (
        1 <= block.get("quote_depth", 0) <= 4
    ):
        raise InvalidReadpack("quote blocks need a 1-4 depth")
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
        if version == "1.1":
            runs = sentence.get("runs")
            if not runs:
                raise InvalidReadpack("a 1.1 sentence must carry non-empty runs")
            if "".join(run.get("text", "") for run in runs) != sentence["text"]:
                raise InvalidReadpack("sentence runs must concatenate to the sentence text")
        if not (
            previous_end <= sentence["audio_start_sample"]
            < sentence["audio_end_sample"]
            <= max_sample
        ):
            raise InvalidReadpack("sentence audio ranges must be ordered and bounded")
        expected_start_ms = (
            sentence["audio_start_sample"] * 1000 // audio["sample_rate_hz"]
        )
        expected_end_ms = (
            sentence["audio_end_sample"] * 1000
            + audio["sample_rate_hz"]
            - 1
        ) // audio["sample_rate_hz"]
        if (
            sentence["audio_start_ms"] != expected_start_ms
            or sentence["audio_end_ms"] != expected_end_ms
            or sentence["audio_end_ms"] > audio["duration_ms"]
        ):
            raise InvalidReadpack("sample and millisecond audio ranges disagree")
        previous_end = sentence["audio_end_sample"]


def _validate_table_block(block: dict[str, Any], version: str, cell_ids: set[str]) -> None:
    header = block.get("header", [])
    rows = block.get("rows", [])
    alignments = block.get("alignments", [])
    translation = block.get("translation_zh")
    if not header:
        raise InvalidReadpack("table blocks need a header row")
    if len(alignments) != len(header):
        raise InvalidReadpack("table alignment count must match the header width")
    if "sentences" in block:
        raise InvalidReadpack("table blocks must not carry sentences")
    if not isinstance(translation, dict) or not translation:
        raise InvalidReadpack("table blocks need a cell-id translation map")
    expected: list[str] = []
    total_characters = 0
    for cell in header:
        expected.append(_validate_cell(cell, version, cell_ids))
        total_characters += len(str(cell.get("text", "")))
    for row in rows:
        if len(row) != len(header):
            raise InvalidReadpack("table rows must match the header width")
        for cell in row:
            expected.append(_validate_cell(cell, version, cell_ids))
            total_characters += len(str(cell.get("text", "")))
    if set(translation) != set(expected):
        raise InvalidReadpack("translated cells must match the original cell identity set")
    if any(not text.strip() for text in translation.values()):
        raise InvalidReadpack("translated table cells must not be empty")
    if total_characters > DEFAULT_LIMITS.max_table_total_characters:
        raise InvalidReadpack(
            "table visible text exceeds "
            f"{DEFAULT_LIMITS.max_table_total_characters} characters"
        )


def _validate_cell(cell: dict[str, Any], version: str, cell_ids: set[str]) -> str:
    cell_id = str(cell["cell_id"])
    if cell_id in cell_ids:
        raise InvalidReadpack("table cell IDs must be unique")
    cell_ids.add(cell_id)
    if version == "1.1":
        runs = cell.get("runs")
        if runs is not None and "".join(run.get("text", "") for run in runs) != cell.get(
            "text", ""
        ):
            raise InvalidReadpack("table cell runs must concatenate to the cell text")
    return cell_id


def _validate_code_block(block: dict[str, Any]) -> None:
    if not block.get("code"):
        raise InvalidReadpack("code blocks need a non-empty body")
    if "translation_zh" in block or "sentences" in block:
        raise InvalidReadpack("code blocks must not carry translations or sentences")
    # The schema bounds code points; the frozen contract limit is UTF-8 bytes
    # and is shared with the content module and the mobile import (§4.4).
    block_bytes = len(str(block["code"]).encode("utf-8"))
    if block_bytes > DEFAULT_LIMITS.max_code_block_bytes:
        raise InvalidReadpack(
            f"code blocks must not exceed {DEFAULT_LIMITS.max_code_block_bytes} bytes"
        )


def _read_json(path: Path) -> dict[str, Any]:
    return cast(dict[str, Any], json.loads(path.read_text(encoding="utf-8")))


def _decode_json(content: bytes, name: str) -> dict[str, Any]:
    if content.startswith(b"\xef\xbb\xbf"):
        raise InvalidReadpack(f"{name} must not contain a BOM")
    try:
        return cast(dict[str, Any], json.loads(content.decode("utf-8")))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise InvalidReadpack(f"invalid JSON in {name}") from error
