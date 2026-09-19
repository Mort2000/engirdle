from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import pytest

from engirdle_pc.modules.production.domain.errors import InvalidJobState, JobNotFound
from engirdle_pc.modules.production.domain.models import (
    JobStatus,
    PipelineConfig,
    ProductionStage,
)
from engirdle_pc.modules.production.infrastructure.sqlalchemy_repository import (
    SqlAlchemyJobRepository,
)

ARTICLE_ID = "art-1"
REVISION = 1


def _config() -> PipelineConfig:
    return PipelineConfig(
        pipeline_version="1",
        segmenter="segmenter",
        translation_adapter="stub",
        translation_provider="provider",
        translation_endpoint="unknown",
        translation_model="model",
        translation_prompt="prompt",
        translation_thinking="none",
        translation_reasoning_effort="low",
        speech_adapter="stub",
        custom_voice_model="none",
        base_model="none",
        speech_generation="unknown",
        voice_profile="voice-profile",
        anchor_sha256="anchor",
        audio_codec="aac-lc",
        audio_bitrate_kbps=64,
        audio_loudness_target_lufs=-18.0,
        audio_true_peak_dbfs=-3.0,
        audio_loudness_range_lu=11.0,
    )


def test_old_job_configuration_keeps_scalar_batching_defaults():
    payload = json.loads(_config().to_json())
    payload.pop("speech_batch_size")
    payload.pop("speech_batching")
    restored = PipelineConfig.from_json(json.dumps(payload))
    assert restored.speech_batch_size == 1
    assert restored.speech_batching == "article-order@v1"


class _FixedClock:
    def __init__(self) -> None:
        self._now = datetime(2026, 1, 1, tzinfo=timezone.utc)

    def now(self) -> datetime:
        return self._now

    def advance(self, seconds: int) -> None:
        self._now += timedelta(seconds=seconds)


class _CounterIds:
    def __init__(self) -> None:
        self._n = 0

    def new(self) -> str:
        self._n += 1
        return f"job-{self._n}"


@pytest.fixture
def jobs(database, seed_article):
    seed_article()
    return SqlAlchemyJobRepository(database, _FixedClock(), _CounterIds())


def test_get_missing_raises_job_not_found(jobs) -> None:
    with pytest.raises(JobNotFound):
        jobs.get("does-not-exist")


def test_claim_next_returns_none_when_nothing_queued(jobs) -> None:
    assert jobs.claim_next() is None


def test_claim_next_claims_oldest_queued_and_increments_attempts(jobs) -> None:
    job = jobs.create(ARTICLE_ID, REVISION, _config())

    claimed = jobs.claim_next()

    assert claimed is not None
    assert claimed.job_id == job.job_id
    assert claimed.status is JobStatus.RUNNING
    assert claimed.stage is ProductionStage.TRANSLATION
    assert claimed.attempts == 1
    assert jobs.claim_next() is None  # nothing else queued


def test_recover_stale_reclaims_null_heartbeat_jobs(jobs, database) -> None:
    jobs.create(ARTICLE_ID, REVISION, _config())
    claimed = jobs.claim_next()
    assert claimed is not None

    # Simulate a worker that died before writing its first heartbeat.
    with database.connect() as connection:
        connection.execute(
            "UPDATE build_jobs SET heartbeat_at = NULL WHERE job_id = ?",
            (claimed.job_id,),
        )

    reclaimed = jobs.recover_stale(lease_seconds=300)

    assert reclaimed == 1
    refreshed = jobs.get(claimed.job_id)
    assert refreshed.status is JobStatus.QUEUED
    assert refreshed.attempts == 1  # recover does not bump attempts; claim_next does
    assert jobs.claim_next() is not None  # reclaimed job is claimable again


def test_claim_next_bumps_attempts_across_recovery(jobs, database) -> None:
    job = jobs.create(ARTICLE_ID, REVISION, _config())
    jobs.claim_next()  # attempts -> 1
    with database.connect() as connection:
        connection.execute(
            "UPDATE build_jobs SET heartbeat_at = NULL WHERE job_id = ?", (job.job_id,)
        )
    jobs.recover_stale(lease_seconds=300)  # back to queued, attempts stays 1
    reclaimed = jobs.claim_next()  # attempts -> 2
    assert reclaimed is not None
    assert reclaimed.attempts == 2


def test_checkpoint_requires_running_job(jobs) -> None:
    job = jobs.create(ARTICLE_ID, REVISION, _config())  # QUEUED, not RUNNING

    with pytest.raises(InvalidJobState):
        jobs.checkpoint(job.job_id, ProductionStage.TRANSLATION)


def test_require_review_requires_running_job(jobs) -> None:
    job = jobs.create(ARTICLE_ID, REVISION, _config())

    with pytest.raises(InvalidJobState):
        jobs.require_review(job.job_id)


def test_set_review_stage_requires_review_job(jobs) -> None:
    job = jobs.create(ARTICLE_ID, REVISION, _config())

    with pytest.raises(InvalidJobState):
        jobs.set_review_stage(job.job_id, ProductionStage.PACKAGING)


def test_retry_requires_failed_or_review_job(jobs) -> None:
    job = jobs.create(ARTICLE_ID, REVISION, _config())  # QUEUED

    with pytest.raises(InvalidJobState):
        jobs.retry(job.job_id)


def test_mark_succeeded_requires_review_job(jobs) -> None:
    job = jobs.create(ARTICLE_ID, REVISION, _config())

    with pytest.raises(InvalidJobState):
        jobs.mark_succeeded(job.job_id)


def test_fail_cannot_regress_a_succeeded_job(jobs) -> None:
    job = jobs.create(ARTICLE_ID, REVISION, _config())
    jobs.claim_next()
    jobs.require_review(job.job_id)
    jobs.mark_succeeded(job.job_id)

    jobs.fail(job.job_id, "late_failure", "should be ignored")  # no-op, no raise

    assert jobs.get(job.job_id).status is JobStatus.SUCCEEDED


def test_retry_preserves_checkpoint(jobs) -> None:
    jobs.create(ARTICLE_ID, REVISION, _config())
    claimed = jobs.claim_next()
    assert claimed is not None
    jobs.checkpoint(claimed.job_id, ProductionStage.SPEECH, checkpoint_json='{"c":1}')
    jobs.require_review(claimed.job_id)  # RUNNING -> REVIEW_REQUIRED

    retried = jobs.retry(claimed.job_id)  # REVIEW_REQUIRED -> QUEUED

    assert retried.status is JobStatus.QUEUED
    assert retried.checkpoint_json == '{"c":1}'  # checkpoint survives retry
