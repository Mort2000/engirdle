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


class CatalogPreparation(Protocol):
    def regenerate_catalog(self, *, content_changed: bool = False) -> object: ...


class CatalogPreparingPublisherControl:
    """Refreshes the public catalog before exposing it on the LAN."""

    def __init__(
        self,
        catalog: CatalogPreparation,
        delegate: PublisherControl,
    ) -> None:
        self._catalog = catalog
        self._delegate = delegate
        self._prepared = False

    def status(self) -> PublisherStatus:
        return self._delegate.status()

    def start(self) -> PublisherStatus:
        status = self._delegate.status()
        if status.running and self._prepared:
            return status
        self._catalog.regenerate_catalog(content_changed=True)
        self._prepared = True
        return self._delegate.start()

    def stop(self) -> PublisherStatus:
        return self._delegate.stop()
