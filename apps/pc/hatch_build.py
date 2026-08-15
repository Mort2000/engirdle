from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

_SKIP_BUILD_ENV = "ENGIRDLE_SKIP_WEB_BUILD"
_CACHE_FILENAME = ".build-cache.json"
_CACHE_SCHEMA = 1
_FRONTEND_DIRNAME = "admin_frontend"
_WEBUI_PACKAGE_PATH = "engirdle_pc/entrypoints/admin_web/webui"

# Directories and files excluded from the cache manifest: dependency and
# output trees are not build inputs, and the manifest never records itself.
_EXCLUDED_INPUT_DIRS = frozenset({"node_modules", "dist"})
_EXCLUDED_INPUT_FILES = frozenset({_CACHE_FILENAME, "openapi.json"})

# Frontend sources required to rebuild the web UI from an sdist (design §10).
# node_modules and dist are deliberately absent: npm ci restores the former
# from the lockfile and the latter is a build output.
_FRONTEND_SDIST_ENTRIES = (
    "package.json",
    "package-lock.json",
    "index.html",
    "vite.config.ts",
    "tsconfig.json",
    "tsconfig.app.json",
    "tsconfig.node.json",
    "eslint.config.js",
    ".nvmrc",
    "src",
)

_NODE_MISSING_GUIDANCE = "\n".join(
    [
        "npm was not found on PATH; building the engirdle-pc wheel requires Node >= 22",
        "because the admin web UI (admin_frontend) is compiled during the hatch build.",
        "Install Node (see https://nodejs.org) or, in an nvm checkout, run:",
        "  nvm install   # uses admin_frontend/.nvmrc (Node 24)",
        "  nvm use",
        "Alternatively, prebuild the UI (npm ci && npm run build in admin_frontend)",
        f"and set {_SKIP_BUILD_ENV}=1 to reuse admin_frontend/dist without Node.",
    ]
)


class CustomBuildHook(BuildHookInterface):
    """Embed canonical root schemas; prebuild the admin web UI into wheels.

    sdist: include the frontend sources needed for a from-sdist rebuild.
    wheel: ensure ``admin_frontend/dist`` exists (npm build unless cached or
    skipped via ``ENGIRDLE_SKIP_WEB_BUILD=1``) and inject it as the packaged
    ``webui/`` directory, so installing the wheel never requires Node.
    """

    def initialize(self, version: str, build_data: dict[str, Any]) -> None:
        del version
        project_root = Path(self.root)
        if self.target_name not in {"sdist", "wheel"}:
            return

        self._include_contracts(project_root, build_data)

        frontend = project_root / _FRONTEND_DIRNAME
        if self.target_name == "sdist":
            build_data["force_include"].update(_frontend_sdist_mappings(frontend))
        else:
            dist = _ensure_webui_dist(frontend)
            build_data["force_include"][str(dist)] = _WEBUI_PACKAGE_PATH

    def _include_contracts(self, project_root: Path, build_data: dict[str, Any]) -> None:
        """Embed the canonical root schemas without keeping a source copy."""
        if self.target_name == "sdist":
            contracts_root = project_root.parents[1] / "contracts"
            destination_root = "embedded_contracts"
        else:
            repository_contracts = project_root.parents[1] / "contracts"
            contracts_root = (
                repository_contracts
                if repository_contracts.is_dir()
                else project_root / "embedded_contracts"
            )
            destination_root = "engirdle_pc/contracts"

        schemas = (
            ("readpack/v1/schema", "readpack/v1/schema"),
            ("catalog/v1/schema", "catalog/v1/schema"),
            ("dictionary/v1/schema", "dictionary/v1/schema"),
        )
        for source_suffix, destination_suffix in schemas:
            source = contracts_root / source_suffix
            if not source.is_dir():
                raise RuntimeError(f"canonical contract schema directory not found: {source}")
            build_data["force_include"][str(source)] = f"{destination_root}/{destination_suffix}"


def _frontend_sdist_mappings(frontend: Path) -> dict[str, str]:
    """Map the enumerated frontend sources into the sdist."""
    mappings: dict[str, str] = {}
    for entry in _FRONTEND_SDIST_ENTRIES:
        source = frontend / entry
        if not source.exists():
            raise RuntimeError(f"admin frontend sdist source not found: {source}")
        mappings[str(source)] = f"{_FRONTEND_DIRNAME}/{entry}"
    return mappings


def _ensure_webui_dist(frontend: Path) -> Path:
    """Return the frontend dist directory, building it when necessary."""
    dist = frontend / "dist"

    if os.environ.get(_SKIP_BUILD_ENV) == "1":
        _require_dist(dist, context=f"{_SKIP_BUILD_ENV}=1 is set")
        print(f"[admin-web] {_SKIP_BUILD_ENV}=1: reusing prebuilt {dist}", flush=True)
        return dist

    manifest = _input_manifest(frontend)
    if (dist / "index.html").is_file() and _cache_matches(frontend, manifest):
        print("[admin-web] frontend inputs unchanged: reusing dist (cache hit)", flush=True)
        return dist

    _run_npm(_resolve_npm(), frontend)
    _require_dist(dist, context="after npm run build")
    _write_cache(frontend, manifest)
    return dist


def _require_dist(dist: Path, *, context: str) -> None:
    if not (dist / "index.html").is_file():
        raise RuntimeError(
            f"admin frontend build output missing ({context}): "
            f"expected {dist / 'index.html'}; run `npm ci && npm run build` in "
            f"{_FRONTEND_DIRNAME} or unset {_SKIP_BUILD_ENV} to let the build hook do it"
        )


def _resolve_npm() -> str:
    npm = shutil.which("npm")
    if npm:
        return npm
    if sys.platform == "win32":
        npm = shutil.which("npm.cmd")
        if npm:
            return npm
    raise RuntimeError(_NODE_MISSING_GUIDANCE)


def _run_npm(npm: str, frontend: Path) -> None:
    for arguments in ([npm, "ci"], [npm, "run", "build"]):
        print(f"[admin-web] running: {' '.join(arguments)} (cwd={frontend})", flush=True)
        completed = subprocess.run(arguments, cwd=frontend, check=False)
        if completed.returncode != 0:
            raise RuntimeError(
                f"command failed with exit code {completed.returncode}: "
                f"{' '.join(arguments)} (see its output above)"
            )


def _input_manifest(frontend: Path) -> dict[str, str]:
    """Hash every frontend build input, keyed by path relative to the project."""
    manifest: dict[str, str] = {}
    for current, directories, filenames in os.walk(frontend):
        current_path = Path(current)
        if current_path == frontend:
            directories[:] = sorted(d for d in directories if d not in _EXCLUDED_INPUT_DIRS)
        for filename in sorted(filenames):
            relative = current_path.relative_to(frontend) / filename
            if relative.as_posix() in _EXCLUDED_INPUT_FILES:
                continue
            manifest[relative.as_posix()] = _sha256(current_path / filename)
    return manifest


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _cache_matches(frontend: Path, manifest: dict[str, str]) -> bool:
    cache = frontend / _CACHE_FILENAME
    if not cache.is_file():
        return False
    try:
        payload = json.loads(cache.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return payload.get("schema") == _CACHE_SCHEMA and payload.get("inputs") == manifest


def _write_cache(frontend: Path, manifest: dict[str, str]) -> None:
    cache = frontend / _CACHE_FILENAME
    payload = {"schema": _CACHE_SCHEMA, "inputs": manifest}
    cache.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
