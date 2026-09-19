from __future__ import annotations

from pathlib import Path

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.modules.content.public import (
    ArticleRevision,
    NewArticle,
    ProcessingPlan,
)
from engirdle_pc.modules.production.public import JobStatus, ProductionCheckpoint
from engirdle_pc.modules.speech.public import (
    SentenceSpeech,
    SpeechRequest,
    VoiceProfileRef,
)
from engirdle_pc.modules.translation.public import TranslationUnit
from engirdle_pc.shared.infrastructure.runtime import UuidIdentifierGenerator
from tests.speech_fake import StubSpeechAdapter
from tests.translation_fake import FakeTranslationAdapter


class FailSecondUnitOnceTranslator:
    name = "resume-translation-stub"
    provider = "stub-deepseek"
    endpoint = "stub://checkpoint-resume"
    model = "deepseek-v4-flash-stub"

    def __init__(self) -> None:
        self._delegate = FakeTranslationAdapter(UuidIdentifierGenerator())
        self.begin_calls = 0
        self.translated_units: list[str] = []
        self._second_unit_id: str | None = None
        self._failed = False

    def begin(self, revision: ArticleRevision, plan: ProcessingPlan) -> str:
        self.begin_calls += 1
        return self._delegate.begin(revision, plan)

    def translate_unit(
        self,
        revision: ArticleRevision,
        plan: ProcessingPlan,
        unit: TranslationUnit,
        checkpoint_id: str,
    ):
        self.translated_units.append(unit.unit_id)
        if unit.unit_id == self._second_unit_id and not self._failed:
            self._failed = True
            raise RuntimeError("injected second-unit failure")
        return self._delegate.translate_unit(revision, plan, unit, checkpoint_id)


class FailSecondSentenceOnceSpeechAdapter:
    batch_size = 1
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

    def verify_setup(self) -> None:
        self._delegate.verify_setup()

    def synthesize(
        self, sentence_id: str, text: str, target_dir: Path
    ) -> SentenceSpeech:
        self.synthesized_sentences.append(sentence_id)
        if len(set(self.synthesized_sentences)) == 2 and not self._failed:
            self._failed = True
            raise RuntimeError("injected second-sentence failure")
        return self._delegate.synthesize(sentence_id, text, target_dir)

    def synthesize_batch(self, requests: tuple[SpeechRequest, ...], target_dir: Path):
        return tuple(self.synthesize(r.sentence_id, r.text, target_dir) for r in requests)


def test_retry_resumes_after_last_accepted_translation_unit(tmp_path: Path) -> None:
    translator = FailSecondUnitOnceTranslator()
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"),
        translation_adapter=translator,
        speech_adapter=StubSpeechAdapter(),
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
    plan = container.content.processing_plan(revision.article_id, revision.revision)
    unit_ids = plan.translation.unit_ids
    assert len(unit_ids) == 2
    translator._second_unit_id = unit_ids[1]

    assert container.worker.run_once() is True
    failed = container.production.get(job.job_id)
    checkpoint = ProductionCheckpoint.from_json(failed.checkpoint_json)
    assert failed.status is JobStatus.FAILED
    assert checkpoint is not None
    assert checkpoint.accepted_translation_unit_ids == (unit_ids[0],)

    container.production.retry(job.job_id)
    assert container.worker.run_once() is True
    assert container.production.get(job.job_id).status is JobStatus.REVIEW_REQUIRED
    assert translator.begin_calls == 1
    assert translator.translated_units.count(unit_ids[0]) == 1
    assert translator.translated_units.count(unit_ids[1]) == 2


def test_retry_reuses_valid_sentence_pcm_from_checkpoint(
    tmp_path: Path, fake_translator
) -> None:
    synthesizer = FailSecondSentenceOnceSpeechAdapter()
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"),
        translation_adapter=fake_translator,
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
    # The shortest sentence is accepted first; the next one fails once.
    assert synthesizer.synthesized_sentences.count(sentence_ids[0]) == 2
    assert synthesizer.synthesized_sentences.count(sentence_ids[1]) == 1
    assert synthesizer.synthesized_sentences.count(sentence_ids[2]) == 1


def test_voice_profile_change_after_queue_fails_the_job(
    tmp_path: Path, fake_translator
) -> None:
    # Design §4.5.2: a job must never mix voice profile revisions — activating
    # another profile after queueing fails the job instead of producing audio
    # whose manifest snapshot no longer matches reality.
    synthesizer = StubSpeechAdapter()
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"),
        translation_adapter=fake_translator,
        speech_adapter=synthesizer,
    )
    revision = container.content.create(
        NewArticle(
            title="Voice swap",
            body="One sentence only.",
            author=None,
            source_name=None,
            source_url=None,
            license_name="unknown",
        )
    )
    job = container.production.queue(
        container.content.approve(revision.article_id, revision.revision)
    )

    synthesizer.set_voice_profile(
        VoiceProfileRef(
            voice_profile_id="other-profile",
            revision=3,
            anchor_sha256="f" * 64,
        )
    )

    assert container.worker.run_once() is True
    failed = container.production.get(job.job_id)
    assert failed.status is JobStatus.FAILED
    assert failed.error_code == "AdapterContractError"
    assert "voice profile" in (failed.error_message or "")
