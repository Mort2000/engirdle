from __future__ import annotations

import json
from pathlib import Path
from typing import Any, cast
from urllib.parse import urlparse

from jsonschema import Draft202012Validator, FormatChecker  # type: ignore[import-untyped]

from engirdle_pc.modules.publishing.application.errors import InvalidCatalog


class CatalogValidator:
    def __init__(self, contracts_dir: Path) -> None:
        schema_path = contracts_dir / "catalog" / "v1" / "schema" / "catalog.schema.json"
        self._schema = cast(
            dict[str, Any], json.loads(schema_path.read_text(encoding="utf-8"))
        )

    def validate_file(self, path: Path, service_origin: str | None = None) -> None:
        content = path.read_bytes()
        if content.startswith(b"\xef\xbb\xbf"):
            raise InvalidCatalog("catalog JSON must not contain a BOM")
        try:
            payload = cast(dict[str, Any], json.loads(content.decode("utf-8")))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise InvalidCatalog("catalog must be UTF-8 JSON") from error
        self.validate_payload(payload, service_origin)

    def validate_payload(
        self, payload: dict[str, Any], service_origin: str | None = None
    ) -> None:
        validator = Draft202012Validator(
            self._schema, format_checker=FormatChecker()
        )
        errors = sorted(validator.iter_errors(payload), key=lambda error: list(error.path))
        if errors:
            raise InvalidCatalog(f"catalog schema error: {errors[0].message}")

        article_ids: set[str] = set()
        urls: set[str] = set()
        expected_origin = urlparse(service_origin) if service_origin else None
        for package in payload["packages"]:
            article_id = package["article_id"]
            url = package["url"]
            if article_id in article_ids:
                raise InvalidCatalog("catalog exposes an article more than once")
            if url in urls:
                raise InvalidCatalog("catalog package URLs must be unique")
            article_ids.add(article_id)
            urls.add(url)
            if not package["format_version"].startswith("1."):
                raise InvalidCatalog("catalog references an unsupported readpack major")
            parsed = urlparse(url)
            if parsed.scheme or parsed.netloc:
                if expected_origin is None:
                    raise InvalidCatalog("absolute package URL requires a service origin")
                if (parsed.scheme, parsed.netloc) != (
                    expected_origin.scheme,
                    expected_origin.netloc,
                ):
                    raise InvalidCatalog("absolute package URL must be same-origin")
