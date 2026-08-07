from __future__ import annotations

from datetime import datetime, timezone
from uuid import uuid4


class SystemClock:
    def now(self) -> datetime:
        return datetime.now(timezone.utc)


class UuidIdentifierGenerator:
    def new(self) -> str:
        return str(uuid4())
