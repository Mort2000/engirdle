from __future__ import annotations

import json
import logging
import os
import signal
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from threading import Lock
from typing import Protocol

from engirdle_pc.modules.publishing.application.lifecycle import PublisherStatus
from engirdle_pc.shared.application.runtime import Clock, IdentifierGenerator
from engirdle_pc.shared.domain.time import isoformat_utc

LOGGER = logging.getLogger(__name__)


class ManagedPublisherProcess(Protocol):
    @property
    def pid(self) -> int: ...

    def poll(self) -> int | None: ...

    def terminate(self) -> None: ...

    def kill(self) -> None: ...

    def wait(self, timeout: float | None = None) -> int: ...


class PublisherProcessLauncher(Protocol):
    def __call__(self, command: tuple[str, ...]) -> ManagedPublisherProcess: ...


@dataclass(frozen=True)
class _ProcessRecord:
    pid: int
    binding_host: str
    port: int
    started_at: str
    lease_token: str


class PublisherProcessController:
    """Own and recover the separately spawned, read-only LAN process."""

    def __init__(
        self,
        workspace: Path,
        binding_host: str,
        port: int,
        clock: Clock,
        identifiers: IdentifierGenerator,
        launcher: PublisherProcessLauncher | None = None,
    ) -> None:
        self._workspace = workspace
        self._binding_host = binding_host
        self._port = port
        self._clock = clock
        self._identifiers = identifiers
        self._launcher = launcher or _launch_publisher
        self._process: ManagedPublisherProcess | None = None
        self._last_exit_code: int | None = None
        self._lock = Lock()

    @property
    def _record_path(self) -> Path:
        return self._workspace / "publisher-process.json"

    def status(self) -> PublisherStatus:
        with self._lock:
            return self._status_without_lock()

    def start(self) -> PublisherStatus:
        with self._lock:
            status = self._status_without_lock()
            if status.running:
                return status
            lease_token = self._identifiers.new()
            command = (
                sys.executable,
                "-m",
                "engirdle_pc.entrypoints.publisher.main",
                "--workspace",
                str(self._workspace),
                "--host",
                self._binding_host,
                "--port",
                str(self._port),
                "--lease-token",
                lease_token,
            )
            self._process = self._launcher(command)
            record = _ProcessRecord(
                pid=self._process.pid,
                binding_host=self._binding_host,
                port=self._port,
                started_at=isoformat_utc(self._clock.now()),
                lease_token=lease_token,
            )
            self._write_record(record)
            status = self._status_without_lock()
            if not status.running:
                raise RuntimeError(
                    f"publisher process exited during startup ({status.last_exit_code})"
                )
            LOGGER.info(
                "Started LAN publisher",
                extra={"binding_host": status.binding_host, "port": status.port, "pid": status.pid},
            )
            return status

    def stop(self) -> PublisherStatus:
        with self._lock:
            record = self._read_record()
            if self._process is not None and self._process.poll() is None:
                self._process.terminate()
                try:
                    self._last_exit_code = self._process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self._process.kill()
                    self._last_exit_code = self._process.wait(timeout=5)
            elif record is not None and self._record_is_running(record):
                os.kill(record.pid, signal.SIGTERM)
                deadline = time.monotonic() + 5
                while _pid_exists(record.pid) and time.monotonic() < deadline:
                    time.sleep(0.05)
                if _pid_exists(record.pid):
                    os.kill(record.pid, signal.SIGKILL)
            self._record_path.unlink(missing_ok=True)
            LOGGER.info("Stopped LAN publisher", extra={"pid": record.pid if record else None})
            return self._status_without_lock()

    def _status_without_lock(self) -> PublisherStatus:
        if self._process is not None:
            exit_code = self._process.poll()
            if exit_code is None:
                record = self._read_record()
                if record is not None:
                    return _record_status(record)
            else:
                self._last_exit_code = exit_code
                self._record_path.unlink(missing_ok=True)
        record = self._read_record()
        if record is not None and self._record_is_running(record):
            return _record_status(record)
        if record is not None:
            self._record_path.unlink(missing_ok=True)
        return PublisherStatus(
            running=False,
            binding_host=self._binding_host,
            port=self._port,
            started_at=None,
            pid=None,
            last_exit_code=self._last_exit_code,
        )

    def _record_is_running(self, record: _ProcessRecord) -> bool:
        if not _pid_exists(record.pid):
            return False
        proc_cmdline = Path("/proc") / str(record.pid) / "cmdline"
        if not proc_cmdline.is_file():
            return True
        command = proc_cmdline.read_bytes().replace(b"\0", b" ").decode(
            "utf-8", errors="replace"
        )
        return (
            "engirdle_pc.entrypoints.publisher.main" in command
            and record.lease_token in command
        )

    def _read_record(self) -> _ProcessRecord | None:
        try:
            payload = json.loads(self._record_path.read_text(encoding="utf-8"))
            return _ProcessRecord(
                pid=int(payload["pid"]),
                binding_host=str(payload["binding_host"]),
                port=int(payload["port"]),
                started_at=str(payload["started_at"]),
                lease_token=str(payload["lease_token"]),
            )
        except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
            return None

    def _write_record(self, record: _ProcessRecord) -> None:
        self._workspace.mkdir(parents=True, exist_ok=True)
        temporary = self._record_path.with_suffix(".json.tmp")
        temporary.write_text(
            json.dumps(asdict(record), sort_keys=True) + "\n", encoding="utf-8"
        )
        os.replace(temporary, self._record_path)


def _record_status(record: _ProcessRecord) -> PublisherStatus:
    return PublisherStatus(
        running=True,
        binding_host=record.binding_host,
        port=record.port,
        started_at=record.started_at,
        pid=record.pid,
        last_exit_code=None,
    )


def _pid_exists(pid: int) -> bool:
    stat_path = Path("/proc") / str(pid) / "stat"
    if stat_path.is_file():
        try:
            if stat_path.read_text(encoding="utf-8").split()[2] == "Z":
                return False
        except (OSError, IndexError):
            pass
    try:
        os.kill(pid, 0)
    except (OSError, ValueError):
        return False
    return True


def _launch_publisher(command: tuple[str, ...]) -> ManagedPublisherProcess:
    return subprocess.Popen(command)
