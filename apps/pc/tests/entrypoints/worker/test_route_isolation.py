"""Worker route-isolation tests (design §14.2).

The worker may only route narratable sentences to TTS and plan units to the
translation adapter. Code bodies, table cell text and dividers must never
reach any LLM request, session context, journal or TTS call. These tests drive
the real ProductionWorker with the deterministic fakes and inspect what the
adapters actually received.
"""

from __future__ import annotations

from pathlib import Path

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.modules.content.public import NewArticle
from engirdle_pc.modules.production.public import JobStatus
from engirdle_pc.modules.speech.public import SentenceSpeech, SpeechRequest, VoiceProfileRef
from tests.speech_fake import StubSpeechAdapter
from tests.translation_fake import build_fake_translation_adapter

# A unique string that appears ONLY inside the fenced code block.
CODE_SENTINEL = "ZQ7-ROUTE-ISOLATION-SENTINEL"

MARKDOWN_BODY = (
    "# Isolation heading.\n\n"
    "First narrated sentence. Second narrated sentence!\n\n"
    "| Column A | Column B |\n| --- | --- |\n| alpha cell | beta cell |\n\n"
    "---\n\n"
    "```python\n"
    f'SECRET = "{CODE_SENTINEL}"\n'
    "```\n\n"
    "Closing sentence after the code."
)

TABLE_CELL_TEXT = "alpha cell"
TABLE_HEADER_TEXT = "Column B"


class RecordingSpeechAdapter:
    """Wraps the stub tone synthesizer and records every text it receives."""

    name = "stub"
    custom_voice_model = StubSpeechAdapter.custom_voice_model
    base_model = StubSpeechAdapter.base_model
    generation_config_id = StubSpeechAdapter.generation_config_id
    batch_size = 4

    def __init__(self) -> None:
        self._delegate = StubSpeechAdapter()
        self.sentence_ids: list[str] = []
        self.texts: list[str] = []

    @property
    def voice_profile(self) -> VoiceProfileRef:
        return self._delegate.voice_profile

    def verify_setup(self) -> None:
        self._delegate.verify_setup()

    def synthesize(
        self, sentence_id: str, text: str, target_dir: Path
    ) -> SentenceSpeech:
        self.sentence_ids.append(sentence_id)
        self.texts.append(text)
        return self._delegate.synthesize(sentence_id, text, target_dir)

    def synthesize_batch(self, requests: tuple[SpeechRequest, ...], target_dir: Path):
        return tuple(self.synthesize(r.sentence_id, r.text, target_dir) for r in requests)


def _build(tmp_path: Path, translator, speech):
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"),
        translation_adapter=translator,
        speech_adapter=speech,
    )
    revision = container.content.create(
        NewArticle(
            title="Route isolation",
            body=MARKDOWN_BODY,
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
    return container, job, plan


def test_worker_routes_only_plan_units_to_translation_and_sentences_to_speech(
    tmp_path: Path,
) -> None:
    translator = build_fake_translation_adapter()
    speech = RecordingSpeechAdapter()
    container, job, plan = _build(tmp_path, translator, speech)

    assert container.worker.run_once() is True
    assert container.production.get(job.job_id).status is JobStatus.REVIEW_REQUIRED

    # Exactly one request per translation plan unit, keyed by unit id.
    requested_ids = [request.unit_id for request in translator.requests]
    assert requested_ids == list(plan.translation.unit_ids)
    table_ids = [unit.unit_id for unit in plan.translation.table_units]
    assert len(table_ids) == 1
    assert requested_ids.count(table_ids[0]) == 1

    # The code sentinel never appears in any request or the article context.
    assert CODE_SENTINEL not in translator.all_request_text()
    assert all(CODE_SENTINEL not in context for context in translator.contexts)

    # TTS received exactly the narration units, in length order, and nothing
    # from the table or the code block.
    ordered = sorted(plan.narration.units, key=lambda unit: len(unit.text))
    assert speech.texts == [unit.text for unit in ordered]
    assert speech.sentence_ids == [
        unit.sentence_id for unit in ordered
    ]
    assert TABLE_CELL_TEXT not in speech.texts
    assert TABLE_HEADER_TEXT not in speech.texts
    assert CODE_SENTINEL not in speech.texts
    assert all(block_id not in speech.sentence_ids for block_id in table_ids)

    # The audio timeline covers narration sentences only.
    audio = container.audio.get(job.job_id)
    assert [timing.sentence_id for timing in audio.timings] == [
        unit.sentence_id for unit in plan.narration.units
    ]


def test_checkpoint_resume_mid_job_does_not_change_request_counts(
    tmp_path: Path,
) -> None:
    reference_translator = build_fake_translation_adapter()
    reference_speech = RecordingSpeechAdapter()
    reference_container, _reference_job, _reference_plan = _build(
        tmp_path / "reference", reference_translator, reference_speech
    )
    assert reference_container.worker.run_once() is True

    resumed_translator = build_fake_translation_adapter()
    resumed_speech = RecordingSpeechAdapter()
    resumed_container, resumed_job, resumed_plan = _build(
        tmp_path / "resumed", resumed_translator, resumed_speech
    )

    # Interrupt the very first unit: the job fails before accepting anything.
    resumed_translator.fail_next_units(1)
    assert resumed_container.worker.run_once() is True
    failed = resumed_container.production.get(resumed_job.job_id)
    assert failed.status is JobStatus.FAILED
    assert resumed_translator.requests == []

    resumed_container.production.retry(resumed_job.job_id)
    assert resumed_container.worker.run_once() is True
    assert (
        resumed_container.production.get(resumed_job.job_id).status
        is JobStatus.REVIEW_REQUIRED
    )

    # The resumed run makes exactly the same requests as an uninterrupted run:
    # no duplicated table request, no extra LLM call, no re-synthesis.
    resumed_ids = [request.unit_id for request in resumed_translator.requests]
    reference_ids = [request.unit_id for request in reference_translator.requests]
    assert resumed_ids == reference_ids
    resumed_table_ids = [
        unit.unit_id for unit in resumed_plan.translation.table_units
    ]
    for table_id in resumed_table_ids:
        assert resumed_ids.count(table_id) == 1
    assert resumed_speech.sentence_ids == reference_speech.sentence_ids
    assert resumed_speech.texts == reference_speech.texts
