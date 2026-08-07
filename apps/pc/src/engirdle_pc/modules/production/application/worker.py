from __future__ import annotations

import logging

from engirdle_pc.modules.audio.public import AudioService
from engirdle_pc.modules.content.public import ContentService
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
from engirdle_pc.modules.translation.public import TranslationService

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
            self._verify_adapter_snapshot(job)
            checkpoint = ProductionCheckpoint.from_json(job.checkpoint_json)
            if checkpoint is None:
                checkpoint = ProductionCheckpoint(self._translations.begin(revision))
            saved_translation_ids = {
                translation.sentence_id
                for translation in self._translations.list_for_job(job.job_id)
            }
            for block in revision.blocks:
                expected = {sentence.sentence_id for sentence in block.sentences}
                if (
                    block.block_id in checkpoint.accepted_block_ids
                    and expected <= saved_translation_ids
                ):
                    continue
                batch = self._translations.translate_block(
                    job.job_id,
                    revision,
                    block,
                    checkpoint.translation_checkpoint_id,
                )
                actual = {translation.sentence_id for translation in batch.translations}
                saved_translation_ids.update(actual)
                checkpoint = checkpoint.accept_block(block.block_id)
                self._jobs.checkpoint(
                    job.job_id,
                    ProductionStage.TRANSLATION,
                    checkpoint.to_json(),
                )

            self._jobs.checkpoint(
                job.job_id, ProductionStage.SPEECH, checkpoint.to_json()
            )
            target_dir = self._workspace.job_dir(job.job_id)
            speech_items: list[SentenceSpeech] = []
            cached_speech = {
                speech.sentence_id: speech
                for speech in self._speech.reusable_for_job(job.job_id)
            }
            for block in revision.blocks:
                for sentence in block.sentences:
                    cached = cached_speech.get(sentence.sentence_id)
                    if (
                        sentence.sentence_id in checkpoint.synthesized_sentence_ids
                        and cached is not None
                    ):
                        speech_items.append(cached)
                        continue
                    speech = self._speech.synthesize(
                        job.job_id,
                        sentence.sentence_id,
                        sentence.text,
                        target_dir / "pcm",
                    )
                    speech_items.append(speech)
                    checkpoint = checkpoint.accept_speech(sentence.sentence_id)
                    self._jobs.checkpoint(
                        job.job_id,
                        ProductionStage.SPEECH,
                        checkpoint.to_json(),
                    )

            self._jobs.checkpoint(
                job.job_id, ProductionStage.AUDIO, checkpoint.to_json()
            )
            self._audio.build(
                job.job_id, revision, tuple(speech_items), target_dir / "audio"
            )
            self._jobs.require_review(job.job_id)
            LOGGER.info("Production job is ready for review", extra=context)
        except Exception as error:
            LOGGER.exception("Production job failed", extra=context)
            self._jobs.fail(job.job_id, type(error).__name__, str(error))
        return True

    def _verify_adapter_snapshot(self, job: BuildJob) -> None:
        if job.config.translation_adapter != self._translations.name:
            raise AdapterContractError("translation adapter differs from the job snapshot")
        if job.config.speech_adapter != self._speech.name:
            raise AdapterContractError("speech adapter differs from the job snapshot")
