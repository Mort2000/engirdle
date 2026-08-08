from __future__ import annotations

from alembic import context
from sqlalchemy import engine_from_config, pool

# Importing every module's ORM models registers all mapped tables on
# Base.metadata so `alembic revision --autogenerate` sees them. Runtime upgrades
# do not need target_metadata; it is only consulted by autogenerate.
import engirdle_pc.modules.audio.infrastructure.orm
import engirdle_pc.modules.content.infrastructure.orm
import engirdle_pc.modules.packaging.infrastructure.orm
import engirdle_pc.modules.production.infrastructure.orm
import engirdle_pc.modules.publishing.infrastructure.orm
import engirdle_pc.modules.speech.infrastructure.orm
import engirdle_pc.modules.translation.infrastructure.orm  # noqa: F401
from engirdle_pc.shared.infrastructure.database.base import Base

config = context.config

target_metadata = Base.metadata

# Default DB for CLI/autogenerate use. The application injects its own Engine at
# runtime (see migrations_runner.py), so alembic.ini ships a blank sqlalchemy.url;
# fall back to this dev file so `alembic upgrade head` / `revision --autogenerate`
# work out of the box from the repo root.
_DEFAULT_URL = "sqlite:///engirdle_dev.db"


def include_object(object, name, type_, reflected, compare_to):  # type: ignore[no-untyped-def]
    # Alembic creates `alembic_version` itself; it is not in Base.metadata, so
    # exclude it from autogenerate (otherwise it would propose dropping it).
    return not (type_ == "table" and name == "alembic_version")


def run_migrations_offline() -> None:
    url = config.get_main_option("sqlalchemy.url") or _DEFAULT_URL
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        render_as_batch=True,
        include_object=include_object,
        compare_type=False,
    )
    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection) -> None:  # type: ignore[no-untyped-def]
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        render_as_batch=True,
        include_object=include_object,
        # SQLite is dynamically typed (TEXT), so the ORM-inferred String()/Text()
        # types spuriously differ from the baseline columns. Skip type comparison
        # and rely on table/column/nullability/PK + the structural test in
        # tests/integration/sqlite/test_migrations.py to catch real drift.
        compare_type=False,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    # The application injects its own Engine via config.attributes["connection"]
    # (see migrations_runner.py). For CLI use, build from the ini-config URL,
    # falling back to the dev default when alembic.ini ships a blank URL.
    connectable = config.attributes.get("connection", None)
    if connectable is None:
        section = dict(config.get_section(config.config_ini_section) or {})
        if not section.get("sqlalchemy.url"):
            section["sqlalchemy.url"] = _DEFAULT_URL
        connectable = engine_from_config(section, prefix="sqlalchemy.", poolclass=pool.NullPool)
    with connectable.connect() as connection:
        do_run_migrations(connection)


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
