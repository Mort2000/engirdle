from __future__ import annotations

import json
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app
from engirdle_pc.modules.publishing.infrastructure.process_controller import (
    ManagedPublisherProcess,
    PublisherProcessController,
)
from engirdle_pc.shared.infrastructure.runtime import (
    SystemClock,
    UuidIdentifierGenerator,
)


@dataclass
class FakePublisherProcess:
    pid: int = 4312
    exit_code: int | None = None
    terminated: bool = False

    def poll(self) -> int | None:
        return self.exit_code

    def terminate(self) -> None:
        self.terminated = True

    def kill(self) -> None:
        self.exit_code = -9

    def wait(self, timeout: float | None = None) -> int:
        del timeout
        if self.exit_code is None:
            self.exit_code = 0
        return self.exit_code


@dataclass
class CapturingPublisherLauncher:
    process: FakePublisherProcess = field(default_factory=FakePublisherProcess)
    commands: list[tuple[str, ...]] = field(default_factory=list)

    def __call__(self, command: tuple[str, ...]) -> ManagedPublisherProcess:
        self.commands.append(command)
        return self.process


@dataclass
class SleepingPublisherLauncher:
    process: subprocess.Popen[bytes] | None = None

    def __call__(self, command: tuple[str, ...]) -> ManagedPublisherProcess:
        lease_token = command[-1]
        self.process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import time; time.sleep(30)",
                "engirdle_pc.entrypoints.publisher.main",
                lease_token,
            ]
        )
        return self.process


def test_user_can_start_inspect_and_stop_isolated_publisher(tmp_path: Path) -> None:
    launcher = CapturingPublisherLauncher()
    settings = Settings(
        workspace=tmp_path / "workspace",
        publisher_host="192.168.10.20",
        publisher_port=9876,
    )
    container = Container.build(settings, publisher_process_launcher=launcher)
    admin = TestClient(create_admin_app(container))

    initial = admin.get("/api/publisher/status")
    assert initial.json()["running"] is False
    assert initial.json()["binding_url"] == "http://192.168.10.20:9876"
    assert initial.json()["authentication"] == "none"

    started = admin.post("/api/publisher/start")
    assert started.status_code == 202
    assert started.json()["running"] is True
    assert started.json()["pid"] == 4312
    assert started.json()["started_at"] is not None
    assert "engirdle_pc.entrypoints.publisher.main" in launcher.commands[0]
    dashboard = admin.get("/legacy/")
    assert "运行中" in dashboard.text
    assert "没有鉴权" in dashboard.text

    stopped = admin.post("/api/publisher/stop")
    assert stopped.status_code == 200
    assert stopped.json()["running"] is False
    assert stopped.json()["last_exit_code"] == 0
    assert launcher.process.terminated is True


def test_starting_publisher_removes_only_legacy_dictionary_resources(
    tmp_path: Path,
) -> None:
    launcher = CapturingPublisherLauncher()
    settings = Settings(workspace=tmp_path / "workspace")
    container = Container.build(settings, publisher_process_launcher=launcher)
    initial_catalog = container.publishing.regenerate_catalog(content_changed=True)
    dictionaries = settings.public_dir / "dictionaries"
    packages = settings.public_dir / "packages"
    dictionaries.mkdir(parents=True, exist_ok=True)
    packages.mkdir(parents=True, exist_ok=True)
    legacy = dictionaries / "engirdle-en-zh-r2-legacy.dictpack"
    future = dictionaries / "engirdle-en-zh-r3-future.dictpack"
    article = packages / "article.readpack"
    _write_dictionary_pack(legacy, format_version="1.0", schema_version=1)
    _write_dictionary_pack(future, format_version="3.0", schema_version=3)
    article.write_bytes(b"published article")
    legacy_entry = {
        "dictionary_id": "engirdle-en-zh",
        "revision": 2,
        "format_version": "1.0",
        "schema_version": 1,
        "display_name": "Legacy dictionary",
        "size": legacy.stat().st_size,
        "sha256": "a" * 64,
        "url": f"/dictionaries/{legacy.name}",
    }
    (settings.public_dir / "dictionary.json").write_text(
        json.dumps(legacy_entry), encoding="utf-8"
    )
    (settings.public_dir / "catalog.json").write_text(
        json.dumps(
            {
                "catalog_version": initial_catalog.catalog_version,
                "generated_at": "2026-08-09T00:00:00Z",
                "packages": [],
                "dictionaries": [legacy_entry],
            }
        ),
        encoding="utf-8",
    )
    admin = TestClient(create_admin_app(container))

    response = admin.post("/api/publisher/start")

    assert response.status_code == 202
    catalog = json.loads(
        (settings.public_dir / "catalog.json").read_text(encoding="utf-8")
    )
    assert catalog["catalog_version"] == initial_catalog.catalog_version + 1
    assert catalog["dictionaries"] == []
    assert not (settings.public_dir / "dictionary.json").exists()
    assert not legacy.exists()
    assert future.exists()
    assert article.exists()


def test_starting_publisher_preserves_unidentified_dictionary_resources(
    tmp_path: Path,
) -> None:
    launcher = CapturingPublisherLauncher()
    settings = Settings(workspace=tmp_path / "workspace")
    container = Container.build(settings, publisher_process_launcher=launcher)
    dictionaries = settings.public_dir / "dictionaries"
    dictionaries.mkdir(parents=True, exist_ok=True)
    missing_version = dictionaries / "missing-version.dictpack"
    malformed_version = dictionaries / "malformed-version.dictpack"
    _write_dictionary_pack(missing_version, format_version=None, schema_version=1)
    _write_dictionary_pack(
        malformed_version, format_version="1.preview", schema_version=1
    )
    unidentified_entry = {
        "dictionary_id": "engirdle-en-zh",
        "revision": 2,
        "schema_version": 1,
        "display_name": "Unidentified dictionary",
        "size": missing_version.stat().st_size,
        "sha256": "a" * 64,
        "url": f"/dictionaries/{missing_version.name}",
    }
    sidecar = settings.public_dir / "dictionary.json"
    sidecar.write_text(json.dumps(unidentified_entry), encoding="utf-8")

    response = TestClient(create_admin_app(container)).post("/api/publisher/start")

    assert response.status_code == 202
    assert sidecar.exists()
    assert missing_version.exists()
    assert malformed_version.exists()


def test_starting_publisher_excludes_malformed_v2_sidecar_without_deleting_it(
    tmp_path: Path,
) -> None:
    launcher = CapturingPublisherLauncher()
    settings = Settings(workspace=tmp_path / "workspace")
    container = Container.build(settings, publisher_process_launcher=launcher)
    dictionaries = settings.public_dir / "dictionaries"
    dictionaries.mkdir(parents=True, exist_ok=True)
    package = dictionaries / "malformed-v2.dictpack"
    _write_dictionary_pack(package, format_version="2.preview", schema_version=2)
    sidecar = settings.public_dir / "dictionary.json"
    sidecar.write_text(
        json.dumps(
            {
                "dictionary_id": "engirdle-en-zh",
                "revision": 2,
                "format_version": "2.preview",
                "schema_version": 2,
                "display_name": "Unknown v2-like dictionary",
                "size": package.stat().st_size,
                "sha256": "a" * 64,
                "url": f"/dictionaries/{package.name}",
            }
        ),
        encoding="utf-8",
    )

    response = TestClient(create_admin_app(container)).post("/api/publisher/start")

    assert response.status_code == 202
    catalog = json.loads(
        (settings.public_dir / "catalog.json").read_text(encoding="utf-8")
    )
    assert catalog["dictionaries"] == []
    assert sidecar.exists()
    assert package.exists()


def test_starting_an_already_running_publisher_is_idempotent(tmp_path: Path) -> None:
    launcher = CapturingPublisherLauncher()
    settings = Settings(workspace=tmp_path / "workspace")
    container = Container.build(settings, publisher_process_launcher=launcher)
    admin = TestClient(create_admin_app(container))

    assert admin.post("/api/publisher/start").status_code == 202
    first_catalog = (settings.public_dir / "catalog.json").read_text(encoding="utf-8")

    assert admin.post("/api/publisher/start").status_code == 202
    second_catalog = (settings.public_dir / "catalog.json").read_text(encoding="utf-8")

    assert second_catalog == first_catalog
    assert len(launcher.commands) == 1


def test_restarted_management_process_recovers_and_stops_publisher(
    tmp_path: Path,
) -> None:
    workspace = tmp_path / "workspace"
    launcher = SleepingPublisherLauncher()
    original = PublisherProcessController(
        workspace,
        "127.0.0.1",
        9877,
        SystemClock(),
        UuidIdentifierGenerator(),
        launcher,
    )
    started = original.start()
    try:
        recovered = PublisherProcessController(
            workspace,
            "127.0.0.1",
            9877,
            SystemClock(),
            UuidIdentifierGenerator(),
        )
        assert recovered.status().running is True
        assert recovered.status().pid == started.pid
        assert recovered.stop().running is False
        assert launcher.process is not None
        launcher.process.wait(timeout=5)
    finally:
        if launcher.process is not None and launcher.process.poll() is None:
            launcher.process.kill()
            launcher.process.wait(timeout=5)


def _write_dictionary_pack(
    path: Path, *, format_version: str | None, schema_version: int
) -> None:
    manifest: dict[str, object] = {"schema_version": schema_version}
    if format_version is not None:
        manifest["format_version"] = format_version
    with ZipFile(path, "w", compression=ZIP_DEFLATED) as package:
        package.writestr("manifest.json", json.dumps(manifest))
