from __future__ import annotations

import contextlib
import json
import re
import shutil
from pathlib import Path

from engirdle_pc.modules.speech.application.voice_ports import (
    AnchorEngine,
    SpeakerInfo,
    VoiceProfileStore,
)
from engirdle_pc.modules.speech.domain.models import (
    AnchorBatch,
    AnchorCandidate,
    InvalidAnchorRequest,
    VoiceCandidateNotFound,
    VoiceIntegrityError,
    VoiceProfile,
    VoiceProfileNotConfigured,
)
from engirdle_pc.shared.application.runtime import Clock, IdentifierGenerator
from engirdle_pc.shared.domain.time import isoformat_utc
from engirdle_pc.shared.infrastructure.hashing import sha256_file

ANCHOR_TEXT_MAX_LENGTH = 2_000
INSTRUCT_MAX_LENGTH = 1_000
MAX_CANDIDATES_PER_BATCH = 10

# Caller-supplied profile IDs become directory names (design §5.1: paths are
# built from controlled IDs only) — no separators, no dots, no traversal.
_VOICE_PROFILE_ID_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}")


class VoiceProfileService:
    """Anchor audition and confirmed voice profile lifecycle (design §4.5.1)."""

    def __init__(
        self,
        engine: AnchorEngine,
        store: VoiceProfileStore,
        voices_dir: Path,
        clock: Clock,
        identifiers: IdentifierGenerator,
    ) -> None:
        self._engine = engine
        self._store = store
        self._voices_dir = voices_dir
        self._clock = clock
        self._identifiers = identifiers

    def english_speakers(self) -> tuple[SpeakerInfo, ...]:
        return self._engine.english_speakers()

    def create_anchor_batch(
        self,
        *,
        speaker: str,
        anchor_text: str,
        instruct: str,
        seed: int,
        count: int,
    ) -> AnchorBatch:
        speaker_names = {info.name for info in self._engine.english_speakers()}
        if speaker not in speaker_names:
            raise InvalidAnchorRequest(
                f"unsupported English speaker {speaker!r}; choose one of {sorted(speaker_names)}"
            )
        anchor_text = anchor_text.strip()
        if not anchor_text or len(anchor_text) > ANCHOR_TEXT_MAX_LENGTH:
            raise InvalidAnchorRequest(
                f"anchor text must be 1..{ANCHOR_TEXT_MAX_LENGTH} characters"
            )
        instruct = instruct.strip()
        if len(instruct) > INSTRUCT_MAX_LENGTH:
            raise InvalidAnchorRequest(
                f"instruct must be at most {INSTRUCT_MAX_LENGTH} characters"
            )
        if seed < 0:
            raise InvalidAnchorRequest("seed must be non-negative")
        if not 1 <= count <= MAX_CANDIDATES_PER_BATCH:
            raise InvalidAnchorRequest(
                f"candidate count must be 1..{MAX_CANDIDATES_PER_BATCH}"
            )

        batch_id = self._identifiers.new()
        target_dir = self._voices_dir / "_candidates" / batch_id
        generated = self._engine.generate_candidates(
            speaker=speaker,
            anchor_text=anchor_text,
            instruct=instruct,
            seed=seed,
            count=count,
            target_dir=target_dir,
        )
        if len(generated) != count:
            raise VoiceIntegrityError(
                f"anchor engine returned {len(generated)} candidates, expected {count}"
            )
        batch = AnchorBatch(
            batch_id=batch_id,
            speaker=speaker,
            instruct=instruct,
            anchor_text=anchor_text,
            seed=seed,
            custom_voice_model=self._engine.custom_voice_model,
            model_fingerprint=self._engine.model_fingerprint,
            created_at=isoformat_utc(self._clock.now()),
            candidates=tuple(
                AnchorCandidate(
                    batch_id=batch_id,
                    candidate_index=item.candidate_index,
                    seed=item.seed,
                    wav_path=item.wav_path,
                    sha256=item.sha256,
                    duration_ms=item.duration_ms,
                    sample_rate_hz=item.sample_rate_hz,
                )
                for item in generated
            ),
        )
        self._store.save_batch(batch)
        return batch

    def confirm_candidate(
        self,
        batch_id: str,
        candidate_index: int,
        *,
        voice_profile_id: str | None = None,
    ) -> VoiceProfile:
        try:
            batch = self._store.get_batch(batch_id)
        except KeyError as error:
            raise VoiceCandidateNotFound(str(error)) from error
        candidate = next(
            (item for item in batch.candidates if item.candidate_index == candidate_index),
            None,
        )
        if candidate is None:
            raise VoiceCandidateNotFound(
                f"candidate {candidate_index} not found in batch {batch_id}"
            )
        # The frozen transcript is exactly the text the engine read aloud for
        # this candidate (design §4.5.1: anchor WAV <-> transcript must match).
        if not batch.anchor_text:
            raise InvalidAnchorRequest("anchor transcript must not be empty")

        if voice_profile_id is not None and not _VOICE_PROFILE_ID_PATTERN.fullmatch(
            voice_profile_id
        ):
            raise InvalidAnchorRequest(
                "voice_profile_id may only contain letters, digits, '-' and '_'"
            )
        profile_id = voice_profile_id or self._identifiers.new()
        revision = self._store.latest_revision(profile_id) + 1
        anchor_dir = self._voices_dir / profile_id / str(revision)
        anchor_dir.mkdir(parents=True, exist_ok=True)
        anchor_path = anchor_dir / "anchor.wav"
        if anchor_path.exists():
            raise InvalidAnchorRequest(
                f"anchor file already exists for {profile_id}@{revision}; "
                "profile revisions are immutable"
            )
        try:
            try:
                shutil.copyfile(candidate.wav_path, anchor_path)
            except FileNotFoundError as error:
                raise VoiceCandidateNotFound(
                    f"candidate WAV is missing: {candidate.wav_path}"
                ) from error
            anchor_sha256 = sha256_file(anchor_path)
            if anchor_sha256 != candidate.sha256:
                raise VoiceIntegrityError(
                    "copied anchor WAV hash differs from the auditioned candidate"
                )
            now = isoformat_utc(self._clock.now())
            profile = VoiceProfile(
                voice_profile_id=profile_id,
                revision=revision,
                speaker=batch.speaker,
                instruct=batch.instruct,
                anchor_text=batch.anchor_text,
                anchor_wav_path=anchor_path,
                anchor_sha256=anchor_sha256,
                sample_rate_hz=candidate.sample_rate_hz,
                duration_ms=candidate.duration_ms,
                seed=candidate.seed,
                generation_params_json=json.dumps(
                    {
                        "seed": candidate.seed,
                        "max_new_tokens": self._engine.max_new_tokens,
                    },
                    sort_keys=True,
                ),
                custom_voice_model=batch.custom_voice_model,
                model_fingerprint=batch.model_fingerprint,
                source_batch_id=batch_id,
                is_active=True,
                created_at=batch.created_at,
                confirmed_at=now,
            )
            self._store.save_confirmed_profile(profile)
        except Exception:
            # Never leave orphan files behind for a profile that was not
            # persisted; the candidate can be confirmed again afterwards.
            anchor_path.unlink(missing_ok=True)
            anchor_dir.rmdir()
            with contextlib.suppress(OSError):
                # Drop the profile dir if this revision left it empty; other
                # revisions living there make rmdir fail, which is fine.
                anchor_dir.parent.rmdir()
            raise
        return profile

    def activate(self, voice_profile_id: str, revision: int) -> VoiceProfile:
        try:
            self._store.activate(voice_profile_id, revision)
        except KeyError as error:
            raise VoiceCandidateNotFound(str(error)) from error
        return self.active_profile()

    def active_profile(self) -> VoiceProfile:
        profile = self._store.active_profile()
        if profile is None:
            raise VoiceProfileNotConfigured(
                "no confirmed voice profile; create and confirm an anchor first"
            )
        return profile

    def get_batch(self, batch_id: str) -> AnchorBatch:
        try:
            return self._store.get_batch(batch_id)
        except KeyError as error:
            raise VoiceCandidateNotFound(str(error)) from error

    def list_profiles(self) -> tuple[VoiceProfile, ...]:
        return self._store.list_profiles()

    def list_batches(self) -> tuple[AnchorBatch, ...]:
        return self._store.list_batches()
