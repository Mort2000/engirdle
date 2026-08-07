from __future__ import annotations

from datetime import datetime, timezone


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def isoformat_utc(value: datetime | None = None) -> str:
    current = value or utc_now()
    return current.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
