from __future__ import annotations

import json
import sqlite3
import stat
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any, ClassVar, cast
from zipfile import ZipFile

from jsonschema import Draft202012Validator, FormatChecker  # type: ignore[import-untyped]

from engirdle_pc.shared.domain.hashing import sha256_bytes


class DictionaryPackValidator:
    _MAX_PACKAGE_BYTES: ClassVar[int] = 512 * 1024 * 1024
    _MAX_DATABASE_BYTES: ClassVar[int] = 512 * 1024 * 1024
    _MAX_EXPANDED_BYTES: ClassVar[int] = 640 * 1024 * 1024
    _MAX_ENTRIES: ClassVar[int] = 16
    _SOURCE_IDS: ClassVar[set[str]] = {
        "oewn-2025",
        "freedict-eng-zho-2025.11.23",
    }
    _TABLES: ClassVar[set[str]] = {"entries", "forms", "dictionary_meta"}
    _INDEXES: ClassVar[set[str]] = {
        "idx_entries_headword_order",
        "idx_entries_normalized_order",
        "idx_forms_normalized_order",
    }

    def __init__(self, contracts_dir: Path) -> None:
        schema = contracts_dir / "dictionary/v1/schema/manifest.schema.json"
        self._schema = cast(dict[str, Any], json.loads(schema.read_text(encoding="utf-8")))

    def validate(self, package_path: Path) -> None:
        if package_path.stat().st_size > self._MAX_PACKAGE_BYTES:
            raise ValueError("dictpack exceeds the v1 package size limit")
        with ZipFile(package_path) as package:
            entries = package.infolist()
            names = [entry.filename for entry in entries]
            if len(entries) > self._MAX_ENTRIES or len(names) != len(set(names)):
                raise ValueError("dictpack entry count or uniqueness is invalid")
            if "manifest.json" not in names or "dictionary.db" not in names:
                raise ValueError("dictpack is missing a required path")
            total_expanded = 0
            for entry in entries:
                self._validate_entry(entry.filename, entry.external_attr, entry.flag_bits)
                total_expanded += entry.file_size
                if entry.filename == "dictionary.db" and entry.file_size > self._MAX_DATABASE_BYTES:
                    raise ValueError("dictionary database exceeds the v1 size limit")
            if total_expanded > self._MAX_EXPANDED_BYTES:
                raise ValueError("dictpack exceeds the expanded size limit")

            manifest_bytes = package.read("manifest.json")
            if manifest_bytes.startswith(b"\xef\xbb\xbf"):
                raise ValueError("dictionary manifest must not contain a BOM")
            manifest = cast(dict[str, Any], json.loads(manifest_bytes.decode("utf-8")))
            validator = Draft202012Validator(
                self._schema,
                format_checker=FormatChecker(),
            )
            errors = sorted(validator.iter_errors(manifest), key=lambda error: list(error.path))
            if errors:
                raise ValueError(f"dictionary manifest schema error: {errors[0].message}")
            source_ids = [source["source_id"] for source in manifest["sources"]]
            if len(set(source_ids)) != 2 or set(source_ids) != self._SOURCE_IDS:
                raise ValueError("dictionary manifest formal source set is invalid")
            if set(manifest["license_files"]) != {
                name for name in names if name.startswith("licenses/")
            }:
                raise ValueError("dictionary license paths disagree with the manifest")

            database_bytes = package.read("dictionary.db")
            database = manifest["database"]
            if database["size"] != len(database_bytes):
                raise ValueError("dictionary database size mismatch")
            if database["sha256"] != sha256_bytes(database_bytes):
                raise ValueError("dictionary database hash mismatch")
            with tempfile.TemporaryDirectory(prefix="engirdle_dictpack_validate_") as temporary:
                database_path = Path(temporary) / "dictionary.db"
                database_path.write_bytes(database_bytes)
                self._validate_database(database_path, manifest)

    @staticmethod
    def _validate_entry(name: str, external_attributes: int, flags: int) -> None:
        path = PurePosixPath(name)
        if (
            path.is_absolute()
            or ".." in path.parts
            or not name
            or flags & 0x1
            or not (
                name in {"manifest.json", "dictionary.db"}
                or (name.startswith("licenses/") and name.endswith(".txt") and len(path.parts) == 2)
            )
        ):
            raise ValueError("dictpack contains an unsafe or unapproved path")
        mode = external_attributes >> 16
        file_type = stat.S_IFMT(mode)
        if file_type and file_type != stat.S_IFREG:
            raise ValueError("dictpack contains a non-regular entry")

    def _validate_database(self, path: Path, manifest: dict[str, Any]) -> None:
        uri = f"file:{path}?mode=ro"
        with sqlite3.connect(uri, uri=True) as connection:
            connection.execute("PRAGMA query_only = ON")
            if connection.execute("PRAGMA quick_check").fetchone() != ("ok",):
                raise ValueError("dictionary quick_check failed")
            schema = connection.execute(
                "SELECT type, name FROM sqlite_master WHERE type IN ('table', 'index')"
            ).fetchall()
            tables = {name for kind, name in schema if kind == "table"}
            indexes = {name for kind, name in schema if kind == "index"}
            if not tables >= self._TABLES or not indexes >= self._INDEXES:
                raise ValueError("dictionary required schema objects are missing")
            metadata = dict(connection.execute("SELECT key, value FROM dictionary_meta"))
            expected = {
                "dictionary_id": manifest["dictionary_id"],
                "revision": str(manifest["revision"]),
                "schema_version": str(manifest["schema_version"]),
                "normalization_version": manifest["normalization"]["version"],
            }
            if any(metadata.get(key) != value for key, value in expected.items()):
                raise ValueError("dictionary internal metadata mismatch")
            entry_sources = {
                row[0] for row in connection.execute("SELECT DISTINCT source_id FROM entries")
            }
            form_sources = {
                row[0] for row in connection.execute("SELECT DISTINCT source_id FROM forms")
            }
            if not entry_sources <= self._SOURCE_IDS or not form_sources <= self._SOURCE_IDS:
                raise ValueError("dictionary rows contain an unregistered source")
            if connection.execute(
                """
                SELECT 1
                FROM entries
                WHERE NULLIF(TRIM(gloss_en), '') IS NULL
                  AND NULLIF(TRIM(gloss_zh), '') IS NULL
                LIMIT 1
                """
            ).fetchone():
                raise ValueError("dictionary contains an empty sense")
            if connection.execute(
                """
                SELECT 1
                FROM entries
                WHERE sense_id NOT LIKE source_id || '/%'
                LIMIT 1
                """
            ).fetchone():
                raise ValueError("dictionary sense id is outside its source namespace")
