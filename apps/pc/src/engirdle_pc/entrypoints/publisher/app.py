from __future__ import annotations

from fastapi import FastAPI, HTTPException, Path
from fastapi.responses import FileResponse, Response

from engirdle_pc.modules.publishing.infrastructure.query_service import PublisherQueries


def create_publisher_app(queries: PublisherQueries) -> FastAPI:
    app = FastAPI(
        title="Engirdle LAN Publisher",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )

    @app.api_route("/catalog.json", methods=["GET", "HEAD"])
    def catalog() -> Response:
        path = queries.catalog_path
        if not path.is_file():
            raise HTTPException(status_code=404, detail="catalog is not available")
        return FileResponse(
            path,
            media_type="application/json",
            headers={"Cache-Control": "no-cache"},
        )

    @app.api_route("/packages/{opaque_name}", methods=["GET", "HEAD"])
    def package(
        opaque_name: str = Path(pattern=r"^[A-Za-z0-9][A-Za-z0-9._-]{0,199}\.readpack$")
    ) -> Response:
        path = queries.resolve_package(opaque_name)
        if path is None:
            raise HTTPException(status_code=404, detail="published package not found")
        return FileResponse(
            path,
            media_type="application/vnd.engirdle.readpack+zip",
            filename=opaque_name,
            headers={"Cache-Control": "public, max-age=31536000, immutable"},
        )

    return app
