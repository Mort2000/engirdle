from __future__ import annotations

from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    """Shared declarative base for all ORM-mapped tables.

    Modules register their ORM models on this single ``Base`` so that Alembic's
    ``target_metadata`` sees every table for autogeneration. Note that the ORM
    metadata is used for read/write mapping only; DDL authority lives with the
    migration system (Alembic), never ``Base.metadata.create_all``.
    """
