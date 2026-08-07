from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True)
class PublisherStatus:
    running: bool
    binding_host: str
    port: int
    started_at: str | None
    pid: int | None
    last_exit_code: int | None

    @property
    def binding_url(self) -> str:
        host = f"[{self.binding_host}]" if ":" in self.binding_host else self.binding_host
        return f"http://{host}:{self.port}"


class PublisherControl(Protocol):
    def status(self) -> PublisherStatus: ...

    def start(self) -> PublisherStatus: ...

    def stop(self) -> PublisherStatus: ...
