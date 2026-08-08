from __future__ import annotations

import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from sqlalchemy import Engine, create_engine, event
from sqlalchemy.orm import Session, sessionmaker

from engirdle_pc.shared.infrastructure.database.migrations_runner import run_migrations


class Database:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._engine = create_engine(
            f"sqlite:///{path}",
            connect_args={"timeout": 30},
        )

        @event.listens_for(self._engine, "connect")
        def _set_sqlite_pragmas(dbapi_connection: sqlite3.Connection, _record: object) -> None:
            # Mirror the PRAGMAs applied by ``connect()`` so SQLAlchemy-managed
            # connections enforce foreign keys and use WAL just like the raw ones.
            cursor = dbapi_connection.cursor()
            cursor.execute("PRAGMA foreign_keys = ON")
            cursor.execute("PRAGMA journal_mode = WAL")
            cursor.close()

        self._session_factory: sessionmaker[Session] = sessionmaker(
            self._engine,
            expire_on_commit=False,
        )

    @property
    def engine(self) -> Engine:
        return self._engine

    @property
    def sessions(self) -> sessionmaker[Session]:
        return self._session_factory

    def initialize(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        run_migrations(self._engine)

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.path, timeout=30)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA journal_mode = WAL")
        try:
            yield connection
            connection.commit()
        except BaseException:
            connection.rollback()
            raise
        finally:
            connection.close()
