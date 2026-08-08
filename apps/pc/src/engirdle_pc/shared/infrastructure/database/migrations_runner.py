from __future__ import annotations

from pathlib import Path

from alembic import command
from alembic.config import Config
from sqlalchemy import Engine

# The Alembic script directory ships inside the package (next to this module).
_SCRIPT_LOCATION = Path(__file__).with_name("alembic")


def run_migrations(engine: Engine) -> None:
    """Apply all pending Alembic migrations against ``engine``.

    The application's own Engine is injected into the Alembic config so that
    ``env.py`` runs online against the same connections (with the PRAGMA event
    listeners) instead of a URL read from an ini file.
    """
    config = Config()
    config.set_main_option("script_location", str(_SCRIPT_LOCATION))
    config.attributes["connection"] = engine
    command.upgrade(config, "head")
