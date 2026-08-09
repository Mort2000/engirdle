"""Set the outward catalog version floor before resource-only updates.

Revision ID: 0003_catalog_version_floor
Revises: 0002_voice_profiles
Create Date: 2026-08-09
"""

from __future__ import annotations

from alembic import op

revision = "0003_catalog_version_floor"
down_revision = "0002_voice_profiles"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        "UPDATE system_metadata SET value = '1' "
        "WHERE key = 'catalog_version' AND CAST(value AS INTEGER) < 1"
    )


def downgrade() -> None:
    # Version counters are monotonic outward state; never decrement them.
    pass
