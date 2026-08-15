"""Export the admin OpenAPI schema for the typed frontend contract.

Read-only helper for the API type generation pipeline (design §11): builds
the admin app against a throwaway workspace and fetches ``/openapi.json``
through FastAPI's ``TestClient`` — no server process is started. The schema
feeds ``npm run gen:api`` (openapi-typescript), which regenerates
``admin_frontend/src/api/types.generated.ts``; CI regenerates and diffs so
the committed types can never drift from the backend.

Usage (from ``apps/pc``)::

    uv run python scripts/export_openapi.py [--output PATH]

The default output is ``admin_frontend/openapi.json`` (gitignored; the
committed artifact is the generated TypeScript, not this intermediate).
"""

from __future__ import annotations

import argparse
import json
import tempfile
from pathlib import Path

from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app

DEFAULT_OUTPUT = (
    Path(__file__).resolve().parents[1] / "admin_frontend" / "openapi.json"
)


def export_schema(output: Path) -> None:
    """Write the admin app's OpenAPI document to ``output``.

    The container is built over a temporary workspace purely so route
    registration has its dependencies; no request touches the database and
    nothing outside ``output`` is written.
    """
    with tempfile.TemporaryDirectory() as temporary:
        container = Container.build(
            Settings(workspace=Path(temporary) / "workspace")
        )
        client = TestClient(create_admin_app(container))
        response = client.get("/openapi.json")
        response.raise_for_status()
        document = response.json()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(document, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"OpenAPI schema written to {output}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Export the admin OpenAPI schema without running a server."
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"Destination path (default: {DEFAULT_OUTPUT})",
    )
    args = parser.parse_args()
    export_schema(args.output)


if __name__ == "__main__":
    main()
