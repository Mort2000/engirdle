"""In-process SSE hub for job progress streaming (design §8.2/§8.3).

The worker is a separate process that persists progress to SQLite, so the
admin app cannot subscribe to in-memory events. Instead, one shared polling
task per ``job_id`` re-reads the persisted job state on a fixed interval
(default 1s), diffs it against the previous read and broadcasts only real
changes to every connected subscriber. Reads run through ``anyio.to_thread``
because the repository stack is synchronous SQLAlchemy — the event loop must
never block on SQLite.

Event protocol (§8.2):

- ``snapshot`` — first event on connect/reconnect, full job detail payload
  plus the derived progress (re-sending it makes reconnection idempotent);
- ``progress`` — the progress object alone, only when it changed;
- ``status`` — full job + progress payload on every status transition.

Every event carries a strictly increasing id. Streams close normally after a
terminal status (``succeeded``/``failed``); ``review_required`` is a dwell
state that keeps the stream open because publishing advances the job again.
When the last subscriber of a job disconnects, its poller stops so no task
spins without an audience.
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass, field

import anyio

from engirdle_pc.modules.production.public import JobNotFound, JobStatus

LOGGER = logging.getLogger(__name__)

SNAPSHOT_EVENT = "snapshot"
PROGRESS_EVENT = "progress"
STATUS_EVENT = "status"

STREAM_TERMINAL_STATUSES = frozenset({JobStatus.SUCCEEDED, JobStatus.FAILED})
"""Statuses that end a stream; ``review_required`` dwells until publishing."""


@dataclass(frozen=True)
class JobEventState:
    """One full read of a job's persisted state, ready to be diffed.

    ``job`` is the complete detail payload (identical in shape to
    ``GET /api/jobs/{id}``, including its embedded ``progress`` field) so the
    snapshot event can carry it verbatim.
    """

    job: dict[str, object]
    progress: dict[str, object]
    status: JobStatus


StateReader = Callable[[str], JobEventState]
"""Sync reader that loads a job's state; executed on the thread pool."""


@dataclass(frozen=True)
class SseEvent:
    """One server-sent event frame ready for delivery."""

    id: int
    event: str
    data: str


def is_stream_terminal(status: JobStatus) -> bool:
    return status in STREAM_TERMINAL_STATUSES


def _state_payload(state: JobEventState) -> dict[str, object]:
    """The ``snapshot``/``status`` payload: job detail plus progress (§8.2)."""
    return {"job": state.job, "progress": state.progress}


def _encode(payload: dict[str, object]) -> str:
    return json.dumps(payload, ensure_ascii=False)


_CLOSE = None


class _JobPoller:
    """The shared per-job polling task and its subscriber fan-out."""

    def __init__(self, job_id: str, reader: StateReader, poll_interval: float) -> None:
        self.job_id = job_id
        self._reader = reader
        self._poll_interval = poll_interval
        self._subscribers: set[asyncio.Queue[SseEvent | None]] = set()
        self._sequence = 0
        self._last: JobEventState | None = None
        self._task: asyncio.Task[None] | None = None

    @property
    def subscriber_count(self) -> int:
        return len(self._subscribers)

    @property
    def sequence(self) -> int:
        return self._sequence

    def start(self) -> None:
        if self._task is None:
            self._task = asyncio.create_task(
                self._run(), name=f"job-events-{self.job_id}"
            )

    def stop(self) -> None:
        if self._task is not None and not self._task.done():
            self._task.cancel()
        self._task = None

    def add_subscriber(self, queue: asyncio.Queue[SseEvent | None]) -> None:
        self._subscribers.add(queue)

    def remove_subscriber(self, queue: asyncio.Queue[SseEvent | None]) -> None:
        self._subscribers.discard(queue)

    async def _run(self) -> None:
        try:
            while True:
                stop = await self._tick()
                if stop:
                    break
                await asyncio.sleep(self._poll_interval)
        except asyncio.CancelledError:
            raise
        finally:
            # Whatever ended the loop, release every subscriber so no stream
            # waits on a poller that will never publish again.
            for queue in tuple(self._subscribers):
                queue.put_nowait(_CLOSE)
            self._subscribers.clear()

    async def _tick(self) -> bool:
        """One poll cycle; returns True when the stream should close."""
        try:
            state = await anyio.to_thread.run_sync(self._reader, self.job_id)
        except JobNotFound:
            LOGGER.info(
                "Job %s disappeared; closing its event streams", self.job_id
            )
            return True
        except Exception:
            # Transient read failures (e.g. a busy SQLite moment while the
            # worker holds the write lock) must not kill the stream.
            LOGGER.exception(
                "Reading job state for %s failed; retrying next tick",
                self.job_id,
            )
            return False
        return self._publish_diff(state)

    def _publish_diff(self, state: JobEventState) -> bool:
        last = self._last
        self._last = state
        if last is None:
            # Subscribers already received their own connect-time snapshot;
            # the first poll only establishes the diff baseline.
            return is_stream_terminal(state.status)
        if state.progress != last.progress:
            self._broadcast(PROGRESS_EVENT, state.progress)
        if state.status is not last.status:
            self._broadcast(STATUS_EVENT, _state_payload(state))
        return is_stream_terminal(state.status)

    def _broadcast(self, event: str, payload: dict[str, object]) -> None:
        self._sequence += 1
        frame = SseEvent(id=self._sequence, event=event, data=_encode(payload))
        for queue in tuple(self._subscribers):
            queue.put_nowait(frame)


@dataclass
class JobEventBroker:
    """Process-wide registry of per-job pollers (design §8.3).

    One instance lives for the lifetime of the admin app; the SSE endpoint
    subscribes through it so multiple tabs watching the same job share a
    single polling task and a single sequence of event ids.
    """

    reader: StateReader
    poll_interval: float = 1.0
    _pollers: dict[str, _JobPoller] = field(default_factory=dict)

    def has_poller(self, job_id: str) -> bool:
        return job_id in self._pollers

    @property
    def poller_count(self) -> int:
        return len(self._pollers)

    async def subscribe(
        self, job_id: str, snapshot: JobEventState
    ) -> AsyncIterator[SseEvent]:
        """Yield this connection's events: snapshot first, then live diffs.

        ``snapshot`` is the caller's fresh read of the job state (used for a
        clean 404 before any byte is written); if it is already terminal the
        stream delivers just the snapshot and closes without starting a
        poller. The subscriber queue registers BEFORE the snapshot is
        yielded: yielding suspends the generator, and any broadcast fired
        while suspended must already be queued rather than missed.
        """
        poller: _JobPoller | None = None
        queue: asyncio.Queue[SseEvent | None] | None = None
        if not is_stream_terminal(snapshot.status):
            poller = self._pollers.get(job_id)
            if poller is None:
                poller = _JobPoller(job_id, self.reader, self.poll_interval)
                self._pollers[job_id] = poller
            poller.start()
            queue = asyncio.Queue()
            poller.add_subscriber(queue)
        try:
            snapshot_id = poller.sequence if poller is not None else 0
            yield SseEvent(
                id=snapshot_id,
                event=SNAPSHOT_EVENT,
                data=_encode(_state_payload(snapshot)),
            )
            if queue is None or poller is None:
                return
            while True:
                item = await queue.get()
                if item is _CLOSE:
                    return
                yield item
        finally:
            if poller is not None and queue is not None:
                poller.remove_subscriber(queue)
                if poller.subscriber_count == 0:
                    poller.stop()
                    if self._pollers.get(job_id) is poller:
                        del self._pollers[job_id]
