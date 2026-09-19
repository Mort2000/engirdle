from pathlib import Path

import pytest

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.modules.content.public import NewArticle
from engirdle_pc.modules.production.public import JobStatus, ProductionCheckpoint
from engirdle_pc.modules.speech.application.ports import SpeechRequest
from engirdle_pc.modules.speech.public import VoiceProfileRef
from tests.speech_fake import StubSpeechAdapter

TEXTS = (
    "Elephant walks along the river.",
    "Cat sleeps.",
    "A brown dog runs.",
    "Birds sing softly.",
    "Fish swim.",
    "Turtles move very slowly.",
)


class RecordingBatchSpeech(StubSpeechAdapter):
    def __init__(self, fail_call: int | None = None, batch_size: int = 4) -> None:
        super().__init__(batch_size=batch_size)
        self.calls: list[tuple[str, ...]] = []
        self.fail_call = fail_call

    def synthesize_batch(self, requests: tuple[SpeechRequest, ...], target_dir: Path):
        self.calls.append(tuple(request.text for request in requests))
        if len(self.calls) == self.fail_call:
            raise RuntimeError("injected batch failure")
        return super().synthesize_batch(requests, target_dir)


def _queue(tmp_path, fake_translator, speech, texts=TEXTS):
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"),
        translation_adapter=fake_translator, speech_adapter=speech,
    )
    revision = container.content.create(NewArticle(
        title="Speech batches", body=" ".join(texts), author=None,
        source_name=None, source_url=None, license_name="unknown",
    ))
    job = container.production.queue(
        container.content.approve(revision.article_id, revision.revision)
    )
    return container, job


def test_worker_groups_by_length_and_restores_article_audio_order(tmp_path, fake_translator):
    speech = RecordingBatchSpeech()
    container, job = _queue(tmp_path, fake_translator, speech)
    assert container.worker.run_once()
    assert container.production.get(job.job_id).status is JobStatus.REVIEW_REQUIRED
    assert speech.calls == [
        (TEXTS[4], TEXTS[1], TEXTS[2], TEXTS[3]), (TEXTS[5], TEXTS[0]),
    ]
    assert [timing.sentence_id for timing in container.audio.get(job.job_id).timings] == [
        "sentence-1", "sentence-2", "sentence-3", "sentence-4", "sentence-5", "sentence-6",
    ]


def test_equal_length_sentences_keep_original_order(tmp_path, fake_translator):
    speech = RecordingBatchSpeech()
    texts = ("Cats rest.", "Fish swim.", "Dogs bark.", "Birds fly.")
    container, job = _queue(tmp_path, fake_translator, speech, texts=texts)
    assert container.worker.run_once()
    assert container.production.get(job.job_id).status is JobStatus.REVIEW_REQUIRED
    assert speech.calls == [texts]


def test_failed_batch_retry_keeps_accepted_pcm(tmp_path, fake_translator):
    speech = RecordingBatchSpeech(fail_call=2)
    container, job = _queue(tmp_path, fake_translator, speech)
    assert container.worker.run_once()
    failed = container.production.get(job.job_id)
    assert failed.status is JobStatus.FAILED
    checkpoint = ProductionCheckpoint.from_json(failed.checkpoint_json)
    assert checkpoint is not None
    assert set(checkpoint.synthesized_narration_unit_ids) == {
        "sentence-5", "sentence-2", "sentence-3", "sentence-4",
    }
    cached = container.speech.reusable_for_job(job.job_id)
    contents = {item.sentence_id: item.pcm_path.read_bytes() for item in cached}
    container.production.retry(job.job_id)
    assert container.worker.run_once()
    assert container.production.get(job.job_id).status is JobStatus.REVIEW_REQUIRED
    assert speech.calls == [
        (TEXTS[4], TEXTS[1], TEXTS[2], TEXTS[3]),
        (TEXTS[5], TEXTS[0]), (TEXTS[5], TEXTS[0]),
    ]
    assert all(item.pcm_path.read_bytes() == contents[item.sentence_id] for item in cached)


@pytest.mark.parametrize("batch_size,counts", [(1, [1, 1, 1, 1, 1, 1]), (2, [2, 2, 2])])
def test_configurable_batch_size_is_frozen_in_job(tmp_path, fake_translator, batch_size, counts):
    speech = RecordingBatchSpeech(batch_size=batch_size)
    container, job = _queue(tmp_path, fake_translator, speech)
    assert job.config.speech_batch_size == batch_size
    assert job.config.speech_batching == "length-sorted-pending@v1"
    assert container.worker.run_once()
    assert container.production.get(job.job_id).status is JobStatus.REVIEW_REQUIRED
    assert [len(call) for call in speech.calls] == counts


def test_batch_setting_change_after_queue_requires_rebuild(tmp_path, fake_translator):
    speech = RecordingBatchSpeech()
    container, job = _queue(tmp_path, fake_translator, speech)
    speech.batch_size = 2
    assert container.worker.run_once()
    failed = container.production.get(job.job_id)
    assert failed.status is JobStatus.FAILED
    assert failed.error_code == "AdapterContractError"
    assert "batching differs" in failed.error_message
    assert speech.calls == []


def test_corrupt_cached_pcm_is_regenerated_without_rewriting_valid_cache(tmp_path, fake_translator):
    speech = RecordingBatchSpeech(fail_call=2)
    container, job = _queue(tmp_path, fake_translator, speech)
    assert container.worker.run_once()
    cached = container.speech.reusable_for_job(job.job_id)
    corrupted = next(item for item in cached if item.sentence_id == "sentence-3")
    corrupted.pcm_path.write_bytes(b"broken")
    valid = [item for item in cached if item != corrupted]
    modified_times = [item.pcm_path.stat().st_mtime_ns for item in valid]
    container.production.retry(job.job_id)
    assert container.worker.run_once()
    assert container.production.get(job.job_id).status is JobStatus.REVIEW_REQUIRED
    assert speech.calls[-1] == (TEXTS[2], TEXTS[5], TEXTS[0])
    assert [item.pcm_path.stat().st_mtime_ns for item in valid] == modified_times


def test_voice_change_during_batch_does_not_checkpoint_that_batch(tmp_path, fake_translator):
    class ChangingVoice(RecordingBatchSpeech):
        def synthesize_batch(self, requests, target_dir):
            results = super().synthesize_batch(requests, target_dir)
            self.set_voice_profile(VoiceProfileRef("different", 2, "a" * 64))
            return results

    container, job = _queue(tmp_path, fake_translator, ChangingVoice())
    assert container.worker.run_once()
    failed = container.production.get(job.job_id)
    assert failed.status is JobStatus.FAILED
    assert failed.error_code == "AdapterContractError"
    checkpoint = ProductionCheckpoint.from_json(failed.checkpoint_json)
    assert checkpoint.synthesized_narration_unit_ids == ()


@pytest.mark.parametrize("invalid", ["missing", "duplicate", "reordered", "bad_pcm"])
def test_invalid_batch_results_are_not_saved_or_checkpointed(tmp_path, fake_translator, invalid):
    class InvalidBatch(RecordingBatchSpeech):
        def synthesize_batch(self, requests, target_dir):
            results = super().synthesize_batch(requests, target_dir)
            if invalid == "missing":
                return results[:-1]
            if invalid == "duplicate":
                return (results[0],) * len(results)
            if invalid == "reordered":
                return tuple(reversed(results))
            results[-1].pcm_path.write_bytes(b"")
            return results

    container, job = _queue(tmp_path, fake_translator, InvalidBatch())
    assert container.worker.run_once()
    failed = container.production.get(job.job_id)
    assert failed.status is JobStatus.FAILED
    assert failed.error_code == "InvalidSpeechResult"
    assert container.speech.reusable_for_job(job.job_id) == ()
    checkpoint = ProductionCheckpoint.from_json(failed.checkpoint_json)
    assert checkpoint.synthesized_narration_unit_ids == ()
