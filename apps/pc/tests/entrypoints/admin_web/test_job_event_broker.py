"""Unit tests for the in-process JobEventBroker (design §8.3).

The broker is exercised with a scripted fake reader so the diff protocol,
thread-pool offloading, shared polling and lifecycle rules are verified
independently of SQLite or HTTP.
"""

from __future__ import annotations

import asyncio
import json
import threading
from collections.abc import AsyncIterator

import pytest

from engirdle_pc.entrypoints.admin_web.events import (
    JobEventBroker,
    JobEventState,
    SseEvent,
)
from engirdle_pc.modules.production.public import JobStatus, ProductionStage

POLL_INTERVAL = 0.01


def _state(
    status: JobStatus, stage: ProductionStage, percent: float
) -> JobEventState:
    return JobEventState(
        job={"job_id": "job-1", "status": status.value, "stage": stage.value},
        progress={
            "stage": stage.value,
            "stage_index": 0,
            "percent": percent,
            "done_units": 0,
            "total_units": 4,
            "indeterminate": False,
        },
        status=status,
    )


class ScriptedReader:
    """Returns scripted states in order; the last one repeats forever."""

    def __init__(self, states: list[JobEventState | Exception]) -> None:
        self._states = states
        self.calls = 0
        self.thread_ids: list[int] = []

    def __call__(self, job_id: str) -> JobEventState:
        self.calls += 1
        self.thread_ids.append(threading.get_ident())
        index = min(self.calls - 1, len(self._states) - 1)
        state = self._states[index]
        if isinstance(state, Exception):
            raise state
        return state


async def _next(stream: AsyncIterator[SseEvent], timeout: float = 2.0) -> SseEvent:
    return await asyncio.wait_for(stream.__anext__(), timeout)


async def _assert_no_event(
    stream: AsyncIterator[SseEvent], timeout: float = 0.3
) -> None:
    with pytest.raises(asyncio.TimeoutError):
        await asyncio.wait_for(stream.__anext__(), timeout)


def _payload(event: SseEvent) -> dict[str, object]:
    return dict(json.loads(event.data))


def test_snapshot_then_changed_events_only() -> None:
    async def scenario() -> None:
        running_translation = _state(
            JobStatus.RUNNING, ProductionStage.TRANSLATION, 10.0
        )
        unchanged = _state(JobStatus.RUNNING, ProductionStage.TRANSLATION, 10.0)
        running_speech = _state(JobStatus.RUNNING, ProductionStage.SPEECH, 55.0)
        review = _state(JobStatus.REVIEW_REQUIRED, ProductionStage.REVIEW, 97.0)
        reader = ScriptedReader(
            [running_translation, unchanged, running_speech, review]
        )
        broker = JobEventBroker(reader, poll_interval=POLL_INTERVAL)
        stream = broker.subscribe("job-1", running_translation)
        snapshot = await _next(stream)
        assert snapshot.event == "snapshot"
        assert snapshot.id == 0
        progress_speech = await _next(stream)
        assert progress_speech.event == "progress"
        assert "job" not in _payload(progress_speech)
        progress_review = await _next(stream)
        status_review = await _next(stream)
        assert progress_review.event == "progress"
        assert status_review.event == "status"
        # The status event carries the FULL job payload plus progress (§8.2).
        payload = _payload(status_review)
        assert isinstance(payload["job"], dict)
        assert payload["job"] == review.job
        assert payload["progress"] == review.progress
        # The unchanged repeated read publishes nothing.
        await _assert_no_event(stream)
        ids = [
            item.id
            for item in (snapshot, progress_speech, progress_review, status_review)
        ]
        assert ids == sorted(ids)
        await stream.aclose()

    asyncio.run(scenario())


def test_reader_runs_on_the_thread_pool_not_the_event_loop() -> None:
    async def scenario() -> None:
        state = _state(JobStatus.RUNNING, ProductionStage.TRANSLATION, 5.0)
        reader = ScriptedReader([state])
        broker = JobEventBroker(reader, poll_interval=POLL_INTERVAL)
        stream = broker.subscribe("job-1", state)
        await _next(stream)
        while reader.calls == 0:
            await asyncio.sleep(POLL_INTERVAL)
        assert reader.thread_ids[0] != threading.get_ident()
        await stream.aclose()

    asyncio.run(scenario())


def test_terminal_status_closes_the_stream_and_stops_the_poller() -> None:
    async def scenario() -> None:
        running = _state(JobStatus.RUNNING, ProductionStage.SPEECH, 60.0)
        succeeded = _state(JobStatus.SUCCEEDED, ProductionStage.COMPLETE, 100.0)
        reader = ScriptedReader([running, succeeded])
        broker = JobEventBroker(reader, poll_interval=POLL_INTERVAL)
        stream = broker.subscribe("job-1", running)
        assert (await _next(stream)).event == "snapshot"
        # One tick changed both progress and status: the progress event lands
        # first, the full status payload is always the final word.
        progress = await _next(stream)
        assert progress.event == "progress"
        status = await _next(stream)
        assert status.event == "status"
        payload = _payload(status)
        assert isinstance(payload["job"], dict)
        assert payload["job"]["status"] == "succeeded"
        with pytest.raises(StopAsyncIteration):
            await stream.__anext__()
        assert not broker.has_poller("job-1")

    asyncio.run(scenario())


def test_terminal_snapshot_closes_without_starting_a_poller() -> None:
    async def scenario() -> None:
        succeeded = _state(JobStatus.SUCCEEDED, ProductionStage.COMPLETE, 100.0)
        reader = ScriptedReader([succeeded])
        broker = JobEventBroker(reader, poll_interval=POLL_INTERVAL)
        stream = broker.subscribe("job-1", succeeded)
        snapshot = await _next(stream)
        assert snapshot.event == "snapshot"
        with pytest.raises(StopAsyncIteration):
            await stream.__anext__()
        assert broker.poller_count == 0
        assert reader.calls == 0

    asyncio.run(scenario())


def test_multiple_connections_share_one_poller() -> None:
    async def scenario() -> None:
        state = _state(JobStatus.RUNNING, ProductionStage.SPEECH, 60.0)
        reader = ScriptedReader([state])
        broker = JobEventBroker(reader, poll_interval=POLL_INTERVAL)
        first = broker.subscribe("job-1", state)
        second = broker.subscribe("job-1", state)
        await _next(first)
        await _next(second)
        assert broker.poller_count == 1
        await first.aclose()
        # One remaining subscriber keeps the shared poller alive.
        assert broker.poller_count == 1
        await second.aclose()
        assert not broker.has_poller("job-1")

    asyncio.run(scenario())


def test_last_subscriber_leaving_stops_polling() -> None:
    async def scenario() -> None:
        state = _state(JobStatus.RUNNING, ProductionStage.SPEECH, 60.0)
        reader = ScriptedReader([state])
        broker = JobEventBroker(reader, poll_interval=POLL_INTERVAL)
        stream = broker.subscribe("job-1", state)
        await _next(stream)
        while reader.calls == 0:
            await asyncio.sleep(POLL_INTERVAL)
        await stream.aclose()
        assert not broker.has_poller("job-1")
        calls_after_close = reader.calls
        await asyncio.sleep(POLL_INTERVAL * 20)
        assert reader.calls == calls_after_close

    asyncio.run(scenario())


def test_transient_reader_errors_do_not_kill_the_stream() -> None:
    async def scenario() -> None:
        running = _state(JobStatus.RUNNING, ProductionStage.TRANSLATION, 5.0)
        advanced = _state(JobStatus.RUNNING, ProductionStage.TRANSLATION, 25.0)
        reader = ScriptedReader([running, RuntimeError("sqlite busy"), advanced])
        broker = JobEventBroker(reader, poll_interval=POLL_INTERVAL)
        stream = broker.subscribe("job-1", running)
        assert (await _next(stream)).event == "snapshot"
        progress = await _next(stream)
        assert progress.event == "progress"
        assert _payload(progress)["percent"] == 25.0
        await stream.aclose()

    asyncio.run(scenario())
