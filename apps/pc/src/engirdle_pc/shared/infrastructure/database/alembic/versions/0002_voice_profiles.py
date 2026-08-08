"""voice profiles: anchor batches, candidates and confirmed profile revisions.

Revision ID: 0002_voice_profiles
Revises: 0001_baseline
Create Date: 2026-08-08

Adds the Qwen3-TTS voice-configuration tables (design §4.5.1): transient
CustomVoice anchor audition batches/candidates, and immutable confirmed voice
profile revisions with a single active pointer (partial unique index).
"""
from __future__ import annotations

from alembic import op

# revision identifiers, used by Alembic.
revision = "0002_voice_profiles"
down_revision = "0001_baseline"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS voice_anchor_batches (
            batch_id TEXT PRIMARY KEY,
            speaker TEXT NOT NULL,
            instruct TEXT NOT NULL,
            anchor_text TEXT NOT NULL,
            seed INTEGER NOT NULL,
            candidate_count INTEGER NOT NULL,
            custom_voice_model TEXT NOT NULL,
            model_fingerprint TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
        """
    )
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS voice_anchor_candidates (
            batch_id TEXT NOT NULL,
            candidate_index INTEGER NOT NULL,
            seed INTEGER NOT NULL,
            wav_path TEXT NOT NULL,
            sha256 TEXT NOT NULL,
            duration_ms INTEGER NOT NULL,
            sample_rate_hz INTEGER NOT NULL,
            PRIMARY KEY (batch_id, candidate_index),
            FOREIGN KEY (batch_id)
                REFERENCES voice_anchor_batches(batch_id) ON DELETE CASCADE
        )
        """
    )
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS voice_profiles (
            voice_profile_id TEXT NOT NULL,
            revision INTEGER NOT NULL,
            speaker TEXT NOT NULL,
            instruct TEXT NOT NULL,
            anchor_text TEXT NOT NULL,
            anchor_wav_path TEXT NOT NULL,
            anchor_sha256 TEXT NOT NULL,
            sample_rate_hz INTEGER NOT NULL,
            duration_ms INTEGER NOT NULL,
            seed INTEGER NOT NULL,
            generation_params_json TEXT NOT NULL,
            custom_voice_model TEXT NOT NULL,
            model_fingerprint TEXT NOT NULL,
            source_batch_id TEXT NOT NULL,
            is_active INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            confirmed_at TEXT NOT NULL,
            PRIMARY KEY (voice_profile_id, revision)
        )
        """
    )
    op.execute(
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_voice_profiles_single_active
        ON voice_profiles(is_active) WHERE is_active = 1
        """
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS idx_voice_profiles_single_active")
    for table in (
        "voice_profiles",
        "voice_anchor_candidates",
        "voice_anchor_batches",
    ):
        op.execute(f"DROP TABLE IF EXISTS {table}")
