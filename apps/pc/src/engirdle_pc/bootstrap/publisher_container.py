from __future__ import annotations

from dataclasses import dataclass

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.modules.publishing.infrastructure.query_service import PublisherQueries
from engirdle_pc.shared.infrastructure.workspace import Workspace


@dataclass(frozen=True)
class PublisherContainer:
    """Read-only composition root for the LAN-facing process."""

    publisher_queries: PublisherQueries

    @classmethod
    def build(cls, settings: Settings) -> PublisherContainer:
        return cls(publisher_queries=PublisherQueries(Workspace(settings.workspace)))
