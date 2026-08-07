from __future__ import annotations

from pathlib import Path

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.modules.content.public import ArticleRevision, Block, NewArticle
from engirdle_pc.modules.production.public import JobStatus, ProductionCheckpoint
from engirdle_pc.modules.speech.infrastructure.stub_adapter import StubSpeechAdapter
from engirdle_pc.modules.speech.public import (
    SentenceSpeech,
    VoiceProfileRef,
)
from engirdle_pc.modules.translation.infrastructure.stub_adapter import StubTranslationAdapter
from engirdle_pc.modules.translation.public import TranslationBatch
from engirdle_pc.shared.infrastructure.runtime import UuidIdentifierGenerator


class FailSecondBlockOnceTranslator:
    name = "resume-translation-stub"
    provider = "stub-deepseek"
    endpoint = "stub://checkpoint-resume"
    model = "deepseek-v4-flash-stub"

    def __init__(self) -> None:
        self._delegate = StubTranslationAdapter(UuidIdentifierGenerator())
        self.begin_calls = 0
        self.translated_blocks: list[str] = []
        self._failed = False

    def begin(self, revision: ArticleRevision) -> str:
        self.begin_calls += 1
        return self._delegate.begin(revision)

    def translate_block(
        self, revision: ArticleRevision, block: Block, checkpoint_id: str
    ) -> TranslationBatch:
        self.translated_blocks.append(block.block_id)
        if block.order == 1 and not self._failed:
            self._failed = True
            raise RuntimeError("injected second-block failure")
        return self._delegate.translate_block(revision, block, checkpoint_id)


class FailSecondSentenceOnceSpeechAdapter:
    name = "resume-speech-stub"
    custom_voice_model = "Qwen/Qwen3-TTS-CustomVoice@resume-stub"
    base_model = "Qwen/Qwen3-TTS-Base@resume-stub"
    generation_config_id = "tone-pcm@resume-stub"

    def __init__(self) -> None:
        self._delegate = StubSpeechAdapter()
        self.synthesized_sentences: list[str] = []
        self._failed = False

    @property
    def voice_profile(self) -> VoiceProfileRef:
        return self._delegate.voice_profile

    def synthesize(
        self, sentence_id: str, text: str, target_dir: Path
    ) -> SentenceSpeech:
        self.synthesized_sentences.append(sentence_id)
        if len(set(self.synthesized_sentences)) == 2 and not self._failed:
            self._failed = True
            raise RuntimeError("injected second-sentence failure")
        return self._delegate.synthesize(sentence_id, text, target_dir)


def test_retry_resumes_after_last_accepted_translation_block(tmp_path: Path) -> None:
    translator = FailSecondBlockOnceTranslator()
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"),
        translation_adapter=translator,
    )
    revision = container.content.create(
        NewArticle(
            title="Resume",
            body="First block.\n\nSecond block.",
            author=None,
            source_name=None,
            source_url=None,
            license_name="unknown",
        )
    )
    job = container.production.queue(
        container.content.approve(revision.article_id, revision.revision)
    )

    assert container.worker.run_once() is True
    failed = container.production.get(job.job_id)
    checkpoint = ProductionCheckpoint.from_json(failed.checkpoint_json)
    assert failed.status is JobStatus.FAILED
    assert checkpoint is not None
    assert checkpoint.accepted_block_ids == (revision.blocks[0].block_id,)

    container.production.retry(job.job_id)
    assert container.worker.run_once() is True
    assert container.production.get(job.job_id).status is JobStatus.REVIEW_REQUIRED
    assert translator.begin_calls == 1
    assert translator.translated_blocks.count(revision.blocks[0].block_id) == 1
    assert translator.translated_blocks.count(revision.blocks[1].block_id) == 2


def test_retry_reuses_valid_sentence_pcm_from_checkpoint(tmp_path: Path) -> None:
    synthesizer = FailSecondSentenceOnceSpeechAdapter()
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"),
        speech_adapter=synthesizer,
    )
    revision = container.content.create(
        NewArticle(
            title="PCM resume",
            body="First sentence. Second sentence. Third.",
            author=None,
            source_name=None,
            source_url=None,
            license_name="unknown",
        )
    )
    sentence_ids = tuple(
        sentence.sentence_id
        for block in revision.blocks
        for sentence in block.sentences
    )
    job = container.production.queue(
        container.content.approve(revision.article_id, revision.revision)
    )

    assert container.worker.run_once() is True
    assert container.production.get(job.job_id).status is JobStatus.FAILED
    container.production.retry(job.job_id)
    assert container.worker.run_once() is True

    assert container.production.get(job.job_id).status is JobStatus.REVIEW_REQUIRED
    assert synthesizer.synthesized_sentences.count(sentence_ids[0]) == 1
    assert synthesizer.synthesized_sentences.count(sentence_ids[1]) == 2
    assert synthesizer.synthesized_sentences.count(sentence_ids[2]) == 1
