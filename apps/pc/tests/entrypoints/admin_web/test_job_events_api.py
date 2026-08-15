"""SSE endpoint tests over the real app (design §8.2/§8.3).

Two tiers of coverage:

- The full terminal flow (queued -> ... -> succeeded, stream closes) runs
  through ``TestClient`` streaming: that response ENDS, so TestClient's
  buffered transport can deliver it.
- Unterminated streams (review dwell, reconnect idempotence, shared
  polling, disconnect cleanup) cannot: starlette's TestClient transport
  awaits full app completion before returning, so an open SSE stream would
  hang forever. Those scenarios drive the app's ASGI interface directly
  with a minimal incremental client that also delivers the real
  ``http.disconnect`` message, which is what sse-starlette's disconnect
  watcher listens for.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import threading
import time
from pathlib import Path
from typing import Any

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app

POLL_INTERVAL = 0.05


@pytest.fixture(autouse=True)
def _fresh_sse_exit_event() -> None:
    """Give each test an unbound sse-starlette exit event.

    ``sse_starlette`` keeps a module-level ``asyncio.Event`` bound to the
    first event loop that streams a response; every later test runs in a
    fresh loop and would crash with "bound to a different event loop".
    Production is unaffected (one loop per process); tests must reset it.
    """
    from sse_starlette.sse import AppStatus

    AppStatus.should_exit_event = asyncio.Event()


def _make_app(
    tmp_path: Path, fake_translator: Any, fake_speech: Any
) -> tuple[Container, FastAPI]:
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"),
        translation_adapter=fake_translator,
        speech_adapter=fake_speech,
    )
    return container, create_admin_app(container, event_poll_interval=POLL_INTERVAL)


def _iter_sse(response: Any) -> Any:
    """Parse ``text/event-stream`` frames from a (completed) response."""
    fields: dict[str, str] = {}
    for raw in response.iter_lines():
        line = raw.rstrip("\r")
        if not line:
            if fields:
                yield fields
                fields = {}
            continue
        if line.startswith(":"):
            continue
        name, _, value = line.partition(":")
        fields[name] = value.lstrip(" ")


def _wait_until(predicate: Any, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError("condition not reached within timeout")


def _queue_job(client: TestClient, body: str) -> str:
    article = client.post("/api/articles", json={"title": "SSE", "body": body}).json()
    return client.post(
        f"/api/articles/{article['article_id']}/revisions/1/approve"
    ).json()["job_id"]


class StreamClosed(Exception):
    """The server finished the SSE response."""


class SseAsgiConnection:
    """One incremental in-process SSE request against the ASGI app.

    Response chunks surface on a queue as the app produces them;
    ``disconnect()`` delivers the ASGI ``http.disconnect`` message exactly
    like a dropped TCP connection would.
    """

    def __init__(self, app: FastAPI, path: str) -> None:
        self._app = app
        self._path = path
        self._chunks: asyncio.Queue[bytes | None] = asyncio.Queue()
        self._started = asyncio.Event()
        self._disconnect = asyncio.Event()
        self._request_sent = False
        self._buffer = b""
        self._task: asyncio.Task[None] | None = None
        self.status: int | None = None
        self.headers: dict[str, str] = {}

    async def __aenter__(self) -> SseAsgiConnection:
        scope = {
            "type": "http",
            "asgi": {"version": "3.0"},
            "http_version": "1.1",
            "method": "GET",
            "scheme": "http",
            "path": self._path,
            "raw_path": self._path.encode(),
            "query_string": b"",
            "headers": [],
            "client": ("127.0.0.1", 12345),
            "server": ("testserver", 80),
        }

        async def receive() -> dict[str, Any]:
            if not self._request_sent:
                self._request_sent = True
                return {"type": "http.request", "body": b"", "more_body": False}
            await self._disconnect.wait()
            return {"type": "http.disconnect"}

        async def send(message: dict[str, Any]) -> None:
            if message["type"] == "http.response.start":
                self.status = message["status"]
                self.headers = {
                    key.decode().lower(): value.decode()
                    for key, value in message.get("headers", [])
                }
                self._started.set()
            elif message["type"] == "http.response.body":
                body = message.get("body", b"")
                if body:
                    self._chunks.put_nowait(body)
                if not message.get("more_body", False):
                    self._chunks.put_nowait(None)

        self._task = asyncio.create_task(self._app(scope, receive, send))
        await asyncio.wait_for(self._started.wait(), timeout=5)
        return self

    async def __aexit__(self, *exc_info: object) -> None:
        self._disconnect.set()
        await self.wait_closed()

    async def wait_closed(self, timeout: float = 5.0) -> None:
        if self._task is None:
            return
        try:
            await asyncio.wait_for(self._task, timeout)
        except asyncio.TimeoutError:
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._task

    async def disconnect(self) -> None:
        self._disconnect.set()
        await self.wait_closed()

    async def _next_line(self, timeout: float = 5.0) -> str:
        while b"\n" not in self._buffer:
            item = await asyncio.wait_for(self._chunks.get(), timeout)
            if item is None:
                remainder, self._buffer = self._buffer, b""
                if remainder:
                    return remainder.decode().rstrip("\r")
                raise StreamClosed
            self._buffer += item
        line, self._buffer = self._buffer.split(b"\n", 1)
        return line.decode().rstrip("\r")

    async def next_frame(self, timeout: float = 5.0) -> dict[str, str]:
        fields: dict[str, str] = {}
        while True:
            try:
                line = await self._next_line(timeout)
            except StreamClosed:
                if fields:
                    return fields
                raise
            if not line:
                if fields:
                    return fields
                continue
            if line.startswith(":"):
                continue  # ping comment frame
            name, _, value = line.partition(":")
            fields[name] = value.lstrip(" ")


def test_unknown_job_answers_404_before_any_stream_byte(
    tmp_path: Path, fake_translator: Any, fake_speech: Any
) -> None:
    _container, app = _make_app(tmp_path, fake_translator, fake_speech)
    response = TestClient(app).get("/api/jobs/missing/events")
    assert response.status_code == 404
    assert response.json()["detail"]


def test_stream_runs_to_terminal_and_closes_normally(
    tmp_path: Path, fake_translator: Any, fake_speech: Any
) -> None:
    container, app = _make_app(tmp_path, fake_translator, fake_speech)
    client = TestClient(app)
    job_id = _queue_job(client, "Narrate this sentence. And this one.")

    connected = threading.Event()

    def drive_to_terminal() -> None:
        connected.wait(timeout=10)
        container.worker.run_once()
        container.release.release(job_id)

    worker_thread = threading.Thread(target=drive_to_terminal, daemon=True)
    worker_thread.start()

    frames: list[dict[str, str]] = []
    deadline = time.monotonic() + 30
    with client.stream("GET", f"/api/jobs/{job_id}/events") as response:
        assert response.headers["content-type"].startswith("text/event-stream")
        for index, frame in enumerate(_iter_sse(response)):
            if index == 0:
                # Snapshot delivered — let the worker drive the job forward.
                connected.set()
            frames.append(frame)
            assert time.monotonic() < deadline, "stream never closed"
        # The loop only exits when the server closed the stream itself.
    worker_thread.join(timeout=10)

    assert frames, "no SSE frames received"
    snapshot = frames[0]
    assert snapshot["event"] == "snapshot"
    snapshot_payload = json.loads(snapshot["data"])
    assert snapshot_payload["job"]["job_id"] == job_id
    assert snapshot_payload["job"]["status"] == "queued"
    # The snapshot job payload is exactly the REST detail payload shape:
    # full detail plus embedded progress, plus the progress envelope.
    assert snapshot_payload["progress"] == snapshot_payload["job"]["progress"]
    assert snapshot_payload["progress"]["stage"] == "queued"
    assert snapshot_payload["progress"]["indeterminate"] is True

    status_frames = [frame for frame in frames if frame.get("event") == "status"]
    assert status_frames, "no status event observed"
    final = json.loads(status_frames[-1]["data"])
    assert final["job"]["status"] == "succeeded"
    assert final["job"]["finished_at"]
    assert final["progress"]["stage"] == "complete"
    assert final["progress"]["percent"] == 100.0

    ids = [int(frame["id"]) for frame in frames if "id" in frame]
    assert ids == sorted(ids)
    assert len(set(ids)) == len(ids)

    broker = app.state.job_events
    _wait_until(lambda: not broker.has_poller(job_id))


def test_snapshot_is_idempotent_across_disconnect_and_reconnect(
    tmp_path: Path, fake_translator: Any, fake_speech: Any
) -> None:
    container, app = _make_app(tmp_path, fake_translator, fake_speech)
    client = TestClient(app)
    job_id = _queue_job(client, "Reviewed sentence for reconnection.")
    container.worker.run_once()  # dwell in review_required
    url = f"/api/jobs/{job_id}/events"
    broker = app.state.job_events

    async def scenario() -> None:
        async with SseAsgiConnection(app, url) as first:
            assert first.status == 200
            assert first.headers["content-type"].startswith("text/event-stream")
            first_snapshot = await first.next_frame()
            await first.disconnect()
        # review_required is a dwell state; the dropped connection alone must
        # retire the shared poller (zero subscribers -> stop polling).
        assert not broker.has_poller(job_id)

        async with SseAsgiConnection(app, url) as second:
            second_snapshot = await second.next_frame()
        assert second_snapshot["event"] == "snapshot"
        assert second_snapshot["data"] == first_snapshot["data"]
        payload = json.loads(second_snapshot["data"])
        assert payload["job"]["status"] == "review_required"
        assert payload["progress"]["stage"] == "review"
        assert not broker.has_poller(job_id)

    asyncio.run(scenario())


def test_concurrent_connections_share_one_poller_and_stop_on_zero(
    tmp_path: Path, fake_translator: Any, fake_speech: Any
) -> None:
    _container, app = _make_app(tmp_path, fake_translator, fake_speech)
    client = TestClient(app)
    job_id = _queue_job(client, "Shared polling sentence.")
    url = f"/api/jobs/{job_id}/events"
    broker = app.state.job_events

    async def scenario() -> None:
        async with contextlib.AsyncExitStack() as stack:
            first = await stack.enter_async_context(SseAsgiConnection(app, url))
            second = await stack.enter_async_context(SseAsgiConnection(app, url))
            first_snapshot = await first.next_frame()
            second_snapshot = await second.next_frame()
            assert broker.poller_count == 1
            assert broker.has_poller(job_id)
            assert first_snapshot["event"] == second_snapshot["event"] == "snapshot"
            # Dropping one subscriber keeps the shared poller for the other.
            await first.disconnect()
            assert broker.poller_count == 1
            await second.disconnect()
        assert broker.poller_count == 0
        assert not broker.has_poller(job_id)

    asyncio.run(scenario())


def test_dropped_stream_uses_the_thread_pool_for_reads(
    tmp_path: Path, fake_translator: Any, fake_speech: Any
) -> None:
    """SQLite reads inside the poller never run on the event loop thread."""
    _container, app = _make_app(tmp_path, fake_translator, fake_speech)
    client = TestClient(app)
    job_id = _queue_job(client, "Thread pool sentence.")
    url = f"/api/jobs/{job_id}/events"

    reader_thread_ids: list[int] = []
    broker = app.state.job_events
    original_reader = broker.reader

    def recording_reader(job: str) -> Any:
        reader_thread_ids.append(threading.get_ident())
        return original_reader(job)

    broker.reader = recording_reader

    async def scenario() -> None:
        async with SseAsgiConnection(app, url) as connection:
            await connection.next_frame()
            while len(reader_thread_ids) < 2:
                await asyncio.sleep(POLL_INTERVAL)
            await connection.disconnect()

    asyncio.run(scenario())
    loop_thread = threading.get_ident()
    assert reader_thread_ids
    assert all(thread_id != loop_thread for thread_id in reader_thread_ids)
