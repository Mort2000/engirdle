from __future__ import annotations

from pathlib import Path

from sqlalchemy import func, select, text, update
from sqlalchemy.dialects.sqlite import insert
from sqlalchemy.orm import Session

from engirdle_pc.modules.speech.application.ports import SentenceSpeech
from engirdle_pc.modules.speech.domain.models import (
    AnchorBatch,
    AnchorCandidate,
    VoiceProfile,
)
from engirdle_pc.modules.speech.infrastructure.orm import (
    SentenceAudioRecord,
    VoiceAnchorBatchRecord,
    VoiceAnchorCandidateRecord,
    VoiceProfileRecord,
)
from engirdle_pc.shared.infrastructure.database.connection import Database


class SqlAlchemySpeechRepository:
    """SQLAlchemy 2.0 implementation of the ``SpeechStore`` protocol."""

    def __init__(self, database: Database) -> None:
        self._database = database

    def save(self, job_id: str, speech: SentenceSpeech, adapter_name: str) -> None:
        stmt = insert(SentenceAudioRecord).values(
            job_id=job_id,
            sentence_id=speech.sentence_id,
            pcm_path=str(speech.pcm_path),
            sample_rate_hz=speech.sample_rate_hz,
            sample_count=speech.sample_count,
            adapter_name=adapter_name,
        )
        stmt = stmt.on_conflict_do_update(
            index_elements=["job_id", "sentence_id"],
            set_={
                "pcm_path": stmt.excluded.pcm_path,
                "sample_rate_hz": stmt.excluded.sample_rate_hz,
                "sample_count": stmt.excluded.sample_count,
                "adapter_name": stmt.excluded.adapter_name,
            },
        )
        with self._database.sessions() as session, session.begin():
            session.execute(stmt)

    def list_reusable_for_job(
        self, job_id: str, adapter_name: str
    ) -> tuple[SentenceSpeech, ...]:
        with self._database.sessions() as session, session.begin():
            records = session.scalars(
                select(SentenceAudioRecord)
                .where(
                    SentenceAudioRecord.job_id == job_id,
                    SentenceAudioRecord.adapter_name == adapter_name,
                )
                .order_by(text("rowid"))
            )
            candidates = tuple(
                SentenceSpeech(
                    sentence_id=record.sentence_id,
                    pcm_path=Path(record.pcm_path),
                    sample_rate_hz=record.sample_rate_hz,
                    sample_count=record.sample_count,
                )
                for record in records
            )
        return tuple(speech for speech in candidates if _is_valid_pcm(speech))


def _is_valid_pcm(speech: SentenceSpeech) -> bool:
    return (
        speech.sample_rate_hz > 0
        and speech.sample_count > 0
        and speech.pcm_path.is_file()
        and speech.pcm_path.stat().st_size == speech.sample_count * 2
    )


class SqlAlchemyVoiceProfileRepository:
    """SQLAlchemy 2.0 implementation of the ``VoiceProfileStore`` protocol."""

    def __init__(self, database: Database) -> None:
        self._database = database

    def save_batch(self, batch: AnchorBatch) -> None:
        with self._database.sessions() as session, session.begin():
            session.add(
                VoiceAnchorBatchRecord(
                    batch_id=batch.batch_id,
                    speaker=batch.speaker,
                    instruct=batch.instruct,
                    anchor_text=batch.anchor_text,
                    seed=batch.seed,
                    candidate_count=len(batch.candidates),
                    custom_voice_model=batch.custom_voice_model,
                    model_fingerprint=batch.model_fingerprint,
                    created_at=batch.created_at,
                )
            )
            session.add_all(
                VoiceAnchorCandidateRecord(
                    batch_id=candidate.batch_id,
                    candidate_index=candidate.candidate_index,
                    seed=candidate.seed,
                    wav_path=str(candidate.wav_path),
                    sha256=candidate.sha256,
                    duration_ms=candidate.duration_ms,
                    sample_rate_hz=candidate.sample_rate_hz,
                )
                for candidate in batch.candidates
            )

    def get_batch(self, batch_id: str) -> AnchorBatch:
        with self._database.sessions() as session, session.begin():
            record = session.get(VoiceAnchorBatchRecord, batch_id)
            if record is None:
                raise KeyError(f"voice anchor batch not found: {batch_id}")
            return self._to_batch(session, record)

    def list_batches(self) -> tuple[AnchorBatch, ...]:
        with self._database.sessions() as session, session.begin():
            records = session.scalars(
                select(VoiceAnchorBatchRecord).order_by(text("rowid DESC"))
            )
            return tuple(self._to_batch(session, record) for record in records)

    def save_confirmed_profile(self, profile: VoiceProfile) -> None:
        with self._database.sessions() as session, session.begin():
            session.execute(
                update(VoiceProfileRecord).values(is_active=False)
            )
            session.add(self._to_record(profile, is_active=True))

    def get_profile(self, voice_profile_id: str, revision: int) -> VoiceProfile:
        with self._database.sessions() as session, session.begin():
            record = session.get(VoiceProfileRecord, (voice_profile_id, revision))
            if record is None:
                raise KeyError(
                    f"voice profile not found: {voice_profile_id}@{revision}"
                )
            return _to_profile(record)

    def latest_revision(self, voice_profile_id: str) -> int:
        with self._database.sessions() as session, session.begin():
            value = session.scalar(
                select(func.max(VoiceProfileRecord.revision)).where(
                    VoiceProfileRecord.voice_profile_id == voice_profile_id
                )
            )
            return int(value) if value is not None else 0

    def list_profiles(self) -> tuple[VoiceProfile, ...]:
        with self._database.sessions() as session, session.begin():
            records = session.scalars(
                select(VoiceProfileRecord).order_by(
                    VoiceProfileRecord.voice_profile_id,
                    VoiceProfileRecord.revision.desc(),
                )
            )
            return tuple(_to_profile(record) for record in records)

    def active_profile(self) -> VoiceProfile | None:
        with self._database.sessions() as session, session.begin():
            record = session.scalar(
                select(VoiceProfileRecord).where(
                    VoiceProfileRecord.is_active.is_(True)
                )
            )
            return _to_profile(record) if record is not None else None

    def activate(self, voice_profile_id: str, revision: int) -> None:
        with self._database.sessions() as session, session.begin():
            record = session.get(VoiceProfileRecord, (voice_profile_id, revision))
            if record is None:
                raise KeyError(
                    f"voice profile not found: {voice_profile_id}@{revision}"
                )
            session.execute(
                update(VoiceProfileRecord)
                .where(VoiceProfileRecord.is_active.is_(True))
                .values(is_active=False)
            )
            record.is_active = True

    # -- internals --------------------------------------------------------

    @staticmethod
    def _to_batch(session: Session, record: VoiceAnchorBatchRecord) -> AnchorBatch:
        candidates = session.scalars(
            select(VoiceAnchorCandidateRecord)
            .where(VoiceAnchorCandidateRecord.batch_id == record.batch_id)
            .order_by(VoiceAnchorCandidateRecord.candidate_index)
        )
        return AnchorBatch(
            batch_id=record.batch_id,
            speaker=record.speaker,
            instruct=record.instruct,
            anchor_text=record.anchor_text,
            seed=record.seed,
            custom_voice_model=record.custom_voice_model,
            model_fingerprint=record.model_fingerprint,
            created_at=record.created_at,
            candidates=tuple(
                AnchorCandidate(
                    batch_id=candidate.batch_id,
                    candidate_index=candidate.candidate_index,
                    seed=candidate.seed,
                    wav_path=Path(candidate.wav_path),
                    sha256=candidate.sha256,
                    duration_ms=candidate.duration_ms,
                    sample_rate_hz=candidate.sample_rate_hz,
                )
                for candidate in candidates
            ),
        )

    @staticmethod
    def _to_record(profile: VoiceProfile, *, is_active: bool) -> VoiceProfileRecord:
        return VoiceProfileRecord(
            voice_profile_id=profile.voice_profile_id,
            revision=profile.revision,
            speaker=profile.speaker,
            instruct=profile.instruct,
            anchor_text=profile.anchor_text,
            anchor_wav_path=str(profile.anchor_wav_path),
            anchor_sha256=profile.anchor_sha256,
            sample_rate_hz=profile.sample_rate_hz,
            duration_ms=profile.duration_ms,
            seed=profile.seed,
            generation_params_json=profile.generation_params_json,
            custom_voice_model=profile.custom_voice_model,
            model_fingerprint=profile.model_fingerprint,
            source_batch_id=profile.source_batch_id,
            is_active=is_active,
            created_at=profile.created_at,
            confirmed_at=profile.confirmed_at,
        )


def _to_profile(record: VoiceProfileRecord) -> VoiceProfile:
    return VoiceProfile(
        voice_profile_id=record.voice_profile_id,
        revision=record.revision,
        speaker=record.speaker,
        instruct=record.instruct,
        anchor_text=record.anchor_text,
        anchor_wav_path=Path(record.anchor_wav_path),
        anchor_sha256=record.anchor_sha256,
        sample_rate_hz=record.sample_rate_hz,
        duration_ms=record.duration_ms,
        seed=record.seed,
        generation_params_json=record.generation_params_json,
        custom_voice_model=record.custom_voice_model,
        model_fingerprint=record.model_fingerprint,
        source_batch_id=record.source_batch_id,
        is_active=record.is_active,
        created_at=record.created_at,
        confirmed_at=record.confirmed_at,
    )
