from __future__ import annotations

from sqlalchemy import ForeignKey
from sqlalchemy.orm import Mapped, mapped_column

from engirdle_pc.shared.infrastructure.database.base import Base


class SentenceAudioRecord(Base):
    """ORM mapping for the ``sentence_audio`` table.

    Read/write mapping only; remaining DDL (composite PK) is owned by the
    Alembic baseline.
    """

    __tablename__ = "sentence_audio"

    job_id: Mapped[str] = mapped_column(
        ForeignKey("build_jobs.job_id", ondelete="CASCADE"), primary_key=True
    )
    sentence_id: Mapped[str] = mapped_column(primary_key=True)
    pcm_path: Mapped[str]
    sample_rate_hz: Mapped[int]
    sample_count: Mapped[int]
    adapter_name: Mapped[str]


class VoiceAnchorBatchRecord(Base):
    """ORM mapping for the ``voice_anchor_batches`` table (DDL owned by Alembic)."""

    __tablename__ = "voice_anchor_batches"

    batch_id: Mapped[str] = mapped_column(primary_key=True)
    speaker: Mapped[str]
    instruct: Mapped[str]
    anchor_text: Mapped[str]
    seed: Mapped[int]
    candidate_count: Mapped[int]
    custom_voice_model: Mapped[str]
    model_fingerprint: Mapped[str]
    created_at: Mapped[str]


class VoiceAnchorCandidateRecord(Base):
    """ORM mapping for the ``voice_anchor_candidates`` table."""

    __tablename__ = "voice_anchor_candidates"

    batch_id: Mapped[str] = mapped_column(
        ForeignKey("voice_anchor_batches.batch_id", ondelete="CASCADE"),
        primary_key=True,
    )
    candidate_index: Mapped[int] = mapped_column(primary_key=True)
    seed: Mapped[int]
    wav_path: Mapped[str]
    sha256: Mapped[str]
    duration_ms: Mapped[int]
    sample_rate_hz: Mapped[int]


class VoiceProfileRecord(Base):
    """ORM mapping for the ``voice_profiles`` table."""

    __tablename__ = "voice_profiles"

    voice_profile_id: Mapped[str] = mapped_column(primary_key=True)
    revision: Mapped[int] = mapped_column(primary_key=True)
    speaker: Mapped[str]
    instruct: Mapped[str]
    anchor_text: Mapped[str]
    anchor_wav_path: Mapped[str]
    anchor_sha256: Mapped[str]
    sample_rate_hz: Mapped[int]
    duration_ms: Mapped[int]
    seed: Mapped[int]
    generation_params_json: Mapped[str]
    custom_voice_model: Mapped[str]
    model_fingerprint: Mapped[str]
    source_batch_id: Mapped[str]
    is_active: Mapped[bool]
    created_at: Mapped[str]
    confirmed_at: Mapped[str]
