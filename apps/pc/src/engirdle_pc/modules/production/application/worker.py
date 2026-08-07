from __future__ import annotations

import json
import logging

from engirdle_pc.modules.audio.public import AudioService
from engirdle_pc.modules.content.public import ContentService
from engirdle_pc.modules.production.domain.errors import AdapterContractError
from engirdle_pc.modules.production.domain.models import ProductionStage
from engirdle_pc.modules.production.infrastructure.sqlite_repository import JobRepository
from engirdle_pc.modules.speech.public import SpeechAdapter, SpeechRepository
from engirdle_pc.modules.translation.public import TranslationAdapter, TranslationRepository
from engirdle_pc.shared.infrastructure.workspace import Workspace

LOGGER = logging.getLogger(__name__)


class ProductionWorker:
    def __init__(
        self,
        jobs: JobRepository,
        content: ContentService,
        translator: TranslationAdapter,
        translations: TranslationRepository,
        speech_adapter: SpeechAdapter,
        speech_repository: SpeechRepository,
        audio: AudioService,
        workspace: Workspace,
    ) -> None:
        self._jobs = jobs
        self._content = content
        self._translator = translator
        self._translations = translations
        self._speech_adapter = speech_adapter
        self._speech_repository = speech_repository
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
            checkpoint_id = self._translator.begin(revision)
            accepted_blocks: list[str] = []
            for block in revision.blocks:
                batch = self._translator.translate_block(revision, block, checkpoint_id)
                expected = {sentence.sentence_id for sentence in block.sentences}
                actual = {translation.sentence_id for translation in batch.translations}
                if batch.block_id != block.block_id or actual != expected or len(actual) != len(
                    batch.translations
                ):
                    raise AdapterContractError(
                        f"translation adapter returned a mismatched ID set for {block.block_id}"
                    )
                self._translations.save(
                    job.job_id, batch.translations, self._translator.name
                )
                accepted_blocks.append(block.block_id)
                self._jobs.checkpoint(
                    job.job_id,
                    ProductionStage.TRANSLATION,
                    json.dumps(
                        {"checkpoint_id": checkpoint_id, "accepted_blocks": accepted_blocks},
                        sort_keys=True,
                    ),
                )

            self._jobs.checkpoint(job.job_id, ProductionStage.SPEECH)
            target_dir = self._workspace.job_dir(job.job_id)
            speech_items = []
            for block in revision.blocks:
                for sentence in block.sentences:
                    speech = self._speech_adapter.synthesize(
                        sentence.sentence_id, sentence.text, target_dir / "pcm"
                    )
                    if speech.sentence_id != sentence.sentence_id:
                        raise AdapterContractError("speech adapter changed the sentence ID")
                    self._speech_repository.save(job.job_id, speech, self._speech_adapter.name)
                    speech_items.append(speech)

            self._jobs.checkpoint(job.job_id, ProductionStage.AUDIO)
            self._audio.build(
                job.job_id, revision, tuple(speech_items), target_dir / "audio"
            )
            self._jobs.require_review(job.job_id)
            LOGGER.info("Production job is ready for review", extra=context)
        except Exception as error:
            LOGGER.exception("Production job failed", extra=context)
            self._jobs.fail(job.job_id, type(error).__name__, str(error))
        return True
