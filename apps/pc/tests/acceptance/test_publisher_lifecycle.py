from __future__ import annotations

import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

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
    dashboard = admin.get("/")
    assert "运行中" in dashboard.text
    assert "没有鉴权" in dashboard.text

    stopped = admin.post("/api/publisher/stop")
    assert stopped.status_code == 200
    assert stopped.json()["running"] is False
    assert stopped.json()["last_exit_code"] == 0
    assert launcher.process.terminated is True


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
