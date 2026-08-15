"""SPA build-artifact discovery and hosting helpers (design §9).

The admin web UI ships as prebuilt static files. Two locations may carry
them, checked in order:

1. ``engirdle_pc/entrypoints/admin_web/webui`` — inside the installed
   package (present in prebuilt wheels);
2. ``admin_frontend/dist`` — a local development build in the source tree.

If neither exists the app factory fails at startup with an actionable
message instead of serving a broken shell. The resolution is a pure
function over candidate directories so it stays unit-testable without
touching the real package layout.
"""

from __future__ import annotations

import os
from collections.abc import Sequence
from pathlib import Path

from starlette.responses import Response
from starlette.staticfiles import StaticFiles
from starlette.types import Scope

_PACKAGE_DIR = Path(__file__).resolve().parent
# .../apps/pc/src/engirdle_pc/entrypoints/admin_web -> .../apps/pc
_PROJECT_ROOT = _PACKAGE_DIR.parents[3]

_PACKAGE_WEBUI_DIR = _PACKAGE_DIR / "webui"
_SOURCE_TREE_DIST_DIR = _PROJECT_ROOT / "admin_frontend" / "dist"

_MISSING_WEBUI_MESSAGE = (
    "管理端前端产物缺失: 未找到 webui/index.html (依次检查 "
    "{candidates}). 请从源码构建 (在 apps/pc/admin_frontend 下执行 "
    "npm ci && npm run build), 或安装已内含 "
    "engirdle_pc/entrypoints/admin_web/webui 产物的预构建 wheel."
)


def default_webui_candidates() -> tuple[Path, ...]:
    """Webui lookup order: package dir first, then the source-tree dist."""
    return (_PACKAGE_WEBUI_DIR, _SOURCE_TREE_DIST_DIR)


def resolve_webui_directory(candidates: Sequence[Path] | None = None) -> Path:
    """Return the first candidate directory that contains ``index.html``.

    Raises ``RuntimeError`` when no candidate is usable, with guidance for
    both recovery paths (source build / prebuilt wheel).
    """
    paths = tuple(candidates) if candidates is not None else default_webui_candidates()
    for candidate in paths:
        if (candidate / "index.html").is_file():
            return candidate
    raise RuntimeError(
        _MISSING_WEBUI_MESSAGE.format(candidates=" → ".join(str(p) for p in paths))
    )


class ImmutableStaticFiles(StaticFiles):
    """StaticFiles for content-hashed Vite assets (design §9).

    Filenames embed a content hash, so responses may be cached forever:
    ``Cache-Control: public, max-age=31536000, immutable``.
    """

    def file_response(
        self,
        full_path: str | os.PathLike[str],
        stat_result: os.stat_result,
        scope: Scope,
        status_code: int = 200,
    ) -> Response:
        response = super().file_response(full_path, stat_result, scope, status_code)
        response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
        return response
