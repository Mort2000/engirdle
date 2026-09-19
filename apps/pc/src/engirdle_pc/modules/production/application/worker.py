"""Plan-driven production worker (design §8.5).

The worker never walks the raw revision structure. It iterates exactly the
units of the derived ProcessingPlan: translation units (sentence batches and
whole tables) and narration units (narratable sentences only). Code blocks,
dividers and non-narratable content have no units, so they can never reach an
adapter. Checkpoints record unit identities; resume verifies that claimed
units actually exist in the translation store / PCM cache before skipping.
"""

from __future__ import annotations

import logging

from engirdle_pc.modules.audio.public import AudioService
from engirdle_pc.modules.content.public import ContentService, ProcessingPlan
from engirdle_pc.modules.production.application.ports import (
    JobStore,
    ProductionWorkspace,
)
from engirdle_pc.modules.production.domain.errors import AdapterContractError
from engirdle_pc.modules.production.domain.models import (
    BuildJob,
    ProductionCheckpoint,
    ProductionStage,
)
from engirdle_pc.modules.speech.public import SentenceSpeech, SpeechService
from engirdle_pc.modules.translation.public import TranslationService, TranslationUnit, UnitKind

LOGGER = logging.getLogger(__name__)


class ProductionWorker:
    def __init__(
        self,
        jobs: JobStore,
        content: ContentService,
        translations: TranslationService,
        speech: SpeechService,
        audio: AudioService,
        workspace: ProductionWorkspace,
    ) -> None:
        self._jobs = jobs
        self._content = content
        self._translations = translations
        self._speech = speech
        self._audio = audio
        self._workspace = workspace

    def recover_stale_jobs(self, lease_seconds: int = 300) -> int:
        return self._jobs.recover_stale(lease_seconds)

    def run_once(self) -> bool:
        job = self._jobs.claim_next()
        if job is None:
            return False
        context = {
            "job_id": job.job_id,
            "article_id": job.article_id,
            "revision": job.revision,
        }
        try:
            revision = self._content.get(job.article_id, job.revision)
            plan = self._content.processing_plan(job.article_id, job.revision)
            self._verify_adapter_snapshot(job)
            checkpoint = ProductionCheckpoint.from_json(job.checkpoint_json)
            if checkpoint is None:
                checkpoint = ProductionCheckpoint(self._translations.begin(revision, plan))
            checkpoint = self._translate_units(job, plan, checkpoint)
            speech_items, checkpoint = self._narrate_units(job, plan, checkpoint)
            self._jobs.checkpoint(
                job.job_id, ProductionStage.AUDIO, checkpoint.to_json()
            )
            self._audio.build(
                job.job_id,
                plan.narration,
                tuple(speech_items),
                self._workspace.job_dir(job.job_id) / "audio",
            )
            self._jobs.require_review(job.job_id)
            LOGGER.info("Production job is ready for review", extra=context)
        except Exception as error:
            LOGGER.exception("Production job failed", extra=context)
            self._jobs.fail(job.job_id, type(error).__name__, str(error))
        return True

    def _translate_units(
        self, job: BuildJob, plan: ProcessingPlan, checkpoint: ProductionCheckpoint
    ) -> ProductionCheckpoint:
        revision = self._content.get(job.article_id, job.revision)
        reviewed = {
            unit.unit_id: unit.unit_kind
            for unit in self._translations.list_for_job(job.job_id)
        }
        for unit in plan.translation.units:
            # A checkpointed unit must exist in the store with a matching kind;
            # otherwise the checkpoint is stale and the unit reruns.
            if (
                unit.unit_id in checkpoint.accepted_translation_unit_ids
                and reviewed.get(unit.unit_id) == _unit_kind(unit)
            ):
                continue
            accepted = self._translations.translate_unit(
                job.job_id,
                revision,
                plan,
                unit,
                checkpoint.translation_checkpoint_id,
            )
            reviewed[accepted.translation.block_id] = _unit_kind(unit)
            checkpoint = checkpoint.accept_translation_unit(unit.unit_id)
            self._jobs.checkpoint(
                job.job_id,
                ProductionStage.TRANSLATION,
                checkpoint.to_json(),
            )
        return checkpoint

    def _narrate_units(
        self, job: BuildJob, plan: ProcessingPlan, checkpoint: ProductionCheckpoint
    ) -> tuple[list[SentenceSpeech], ProductionCheckpoint]:
        self._jobs.checkpoint(
            job.job_id, ProductionStage.SPEECH, checkpoint.to_json()
        )
        target_dir = self._workspace.job_dir(job.job_id)
        cached_speech = {
            speech.sentence_id: speech
            for speech in self._speech.reusable_for_job(job.job_id)
        }
        speech_by_id = {
            unit.sentence_id: cached_speech[unit.sentence_id]
            for unit in plan.narration.units
            if unit.sentence_id in checkpoint.synthesized_narration_unit_ids
            and unit.sentence_id in cached_speech
        }
        pending = tuple(
            unit for unit in plan.narration.units if unit.sentence_id not in speech_by_id
        )
        for batch in self._speech.narration_batches(pending):
            # A profile change before or during a batch must fail the job.
            self._verify_adapter_snapshot(job)
            generated = self._speech.synthesize_narration_batch(
                job.job_id,
                batch,
                target_dir / "pcm",
            )
            self._verify_adapter_snapshot(job)
            for speech in generated:
                speech_by_id[speech.sentence_id] = speech
                checkpoint = checkpoint.accept_narration_unit(speech.sentence_id)
                self._jobs.checkpoint(
                    job.job_id, ProductionStage.SPEECH, checkpoint.to_json(),
                )
        return [speech_by_id[unit.sentence_id] for unit in plan.narration.units], checkpoint

    def _verify_adapter_snapshot(self, job: BuildJob) -> None:
        if job.config.translation_adapter != self._translations.name:
            raise AdapterContractError("translation adapter differs from the job snapshot")
        if job.config.speech_adapter != self._speech.name:
            raise AdapterContractError("speech adapter differs from the job snapshot")
        if job.config.speech_generation != self._speech.generation_config_id:
            raise AdapterContractError(
                "speech generation parameters differ from the job snapshot; "
                "rebuild the article with the current speech settings"
            )
        if (
            job.config.speech_batch_size != self._speech.batch_size
            or job.config.speech_batching != self._speech.batching
        ):
            raise AdapterContractError(
                "speech batching differs from the job snapshot; "
                "rebuild the article with the current speech settings"
            )
        # Design §4.5.2: every sentence of one job must use the voice profile
        # revision frozen at queue time — never whatever profile is active now.
        voice = self._speech.voice_profile
        if job.config.voice_profile != f"{voice.voice_profile_id}@{voice.revision}":
            raise AdapterContractError("voice profile differs from the job snapshot")
        if job.config.anchor_sha256 != voice.anchor_sha256:
            raise AdapterContractError("voice anchor differs from the job snapshot")


def _unit_kind(unit: TranslationUnit) -> UnitKind:
    from engirdle_pc.modules.content.domain.plan import TableUnit

    if isinstance(unit, TableUnit):
        return UnitKind.TABLE
    return UnitKind.SENTENCE
