"""Table-driven tests for the derived job progress projection (design §8.1)."""

from __future__ import annotations

import pytest

from engirdle_pc.entrypoints.admin_web.progress import (
    STAGE_ENTRY_PERCENT,
    STAGE_ORDER,
    derive_job_progress,
)
from engirdle_pc.modules.content.public import (
    NarrationPlan,
    NarrationUnit,
    ProcessingPlan,
    RenderDocument,
    Sentence,
    SentenceBatchUnit,
    SentencePauseKind,
    TableAlignment,
    TableUnit,
    TranslationPlan,
)
from engirdle_pc.modules.production.public import (
    BuildJob,
    JobStatus,
    PipelineConfig,
    ProductionCheckpoint,
    ProductionStage,
)


def _config() -> PipelineConfig:
    return PipelineConfig(
        pipeline_version="test@1",
        segmenter="test",
        translation_adapter="stub",
        translation_provider="stub",
        translation_endpoint="stub",
        translation_model="stub",
        translation_prompt="stub",
        translation_thinking="off",
        translation_reasoning_effort="low",
        speech_adapter="stub",
        custom_voice_model="stub",
        base_model="stub",
        speech_generation="stub",
        voice_profile="stub",
        anchor_sha256="0" * 64,
        audio_codec="aac-lc",
        audio_bitrate_kbps=64,
        audio_loudness_target_lufs=-14.0,
        audio_true_peak_dbfs=-1.0,
        audio_loudness_range_lu=11.0,
    )


def _job(
    status: JobStatus,
    stage: ProductionStage,
    checkpoint_json: str | None = None,
) -> BuildJob:
    return BuildJob(
        job_id="job-1",
        article_id="article-1",
        revision=1,
        status=status,
        stage=stage,
        attempts=1,
        config=_config(),
        checkpoint_json=checkpoint_json,
        created_at="2026-08-16T00:00:00+00:00",
        started_at=None,
        heartbeat_at=None,
        finished_at=None,
        error_code=None,
        error_message=None,
    )


def _plan(translation_units: int = 2, narration_sentences: int = 4) -> ProcessingPlan:
    """A synthetic plan: N translation units, M narration sentences.

    Unit identity is deterministic (``t0``…/``s0``…) so checkpoints can be
    expressed as plain id tuples in the test table.
    """
    batches = tuple(
        SentenceBatchUnit(
            block_id=f"t{index}",
            sentences=(Sentence(sentence_id=f"s{index}", order=0, text="text."),),
        )
        for index in range(translation_units)
    )
    table = (
        TableUnit(
            block_id="table-0",
            alignments=(TableAlignment.LEFT,),
            header=(),
            rows=(),
        )
        if translation_units
        else None
    )
    units = (*batches, *((table,) if table else ()))
    narration = tuple(
        NarrationUnit(
            sentence_id=f"s{index}",
            text="text.",
            source_block_id=f"t{index}",
            order=index,
            pause_kind=SentencePauseKind.BLOCK_END,
        )
        for index in range(narration_sentences)
    )
    return ProcessingPlan(
        translation=TranslationPlan(units=units),
        narration=NarrationPlan(units=narration),
        render=RenderDocument(
            article_id="article-1", revision=1, title="Plan", blocks=()
        ),
    )


def _checkpoint(
    accepted: tuple[str, ...] = (), synthesized: tuple[str, ...] = ()
) -> ProductionCheckpoint:
    return ProductionCheckpoint(
        translation_checkpoint_id="checkpoint-1",
        accepted_translation_unit_ids=accepted,
        synthesized_narration_unit_ids=synthesized,
    )


@pytest.mark.parametrize(
    ("status", "stage", "checkpoint", "expected"),
    [
        # queued: waiting for the worker, nothing measurable yet.
        (
            JobStatus.QUEUED,
            ProductionStage.QUEUED,
            None,
            ("queued", 0, 0.0, None, None, True),
        ),
        # translation: one of three units accepted -> 0 + (1/3)*45 = 15.0.
        (
            JobStatus.RUNNING,
            ProductionStage.TRANSLATION,
            _checkpoint(accepted=("t0",)),
            ("translation", 1, 15.0, 1, 3, False),
        ),
        # translation complete (including the whole-table unit).
        (
            JobStatus.RUNNING,
            ProductionStage.TRANSLATION,
            _checkpoint(accepted=("t0", "t1", "table-0")),
            ("translation", 1, 45.0, 3, 3, False),
        ),
        # translation without a checkpoint yet: zero accepted units.
        (
            JobStatus.RUNNING,
            ProductionStage.TRANSLATION,
            None,
            ("translation", 1, 0.0, 0, 3, False),
        ),
        # speech: 1 of 4 sentences -> 45 + 0.25*45 = 56.2 (one decimal).
        (
            JobStatus.RUNNING,
            ProductionStage.SPEECH,
            _checkpoint(accepted=("t0", "t1", "table-0"), synthesized=("s0",)),
            ("speech", 2, 56.2, 1, 4, False),
        ),
        # speech complete.
        (
            JobStatus.RUNNING,
            ProductionStage.SPEECH,
            _checkpoint(
                accepted=("t0", "t1", "table-0"),
                synthesized=("s0", "s1", "s2", "s3"),
            ),
            ("speech", 2, 90.0, 4, 4, False),
        ),
        # audio: short indeterminate stage anchored at its entry weight.
        (
            JobStatus.RUNNING,
            ProductionStage.AUDIO,
            None,
            ("audio", 3, 90.0, None, None, True),
        ),
        # review: fixed full in-stage progress while waiting for a human.
        (
            JobStatus.REVIEW_REQUIRED,
            ProductionStage.REVIEW,
            None,
            ("review", 4, 97.0, None, None, False),
        ),
        # packaging / publishing: short indeterminate stages.
        (
            JobStatus.REVIEW_REQUIRED,
            ProductionStage.PACKAGING,
            None,
            ("packaging", 5, 97.0, None, None, True),
        ),
        (
            JobStatus.REVIEW_REQUIRED,
            ProductionStage.PUBLISHING,
            None,
            ("publishing", 6, 99.0, None, None, True),
        ),
        # complete: terminal success is always a full bar.
        (
            JobStatus.SUCCEEDED,
            ProductionStage.COMPLETE,
            None,
            ("complete", 7, 100.0, None, None, False),
        ),
    ],
)
def test_progress_table(
    status: JobStatus,
    stage: ProductionStage,
    checkpoint: ProductionCheckpoint | None,
    expected: tuple[str, int, float, int | None, int | None, bool],
) -> None:
    progress = derive_job_progress(_job(status, stage), checkpoint, _plan())
    assert (
        progress.stage,
        progress.stage_index,
        progress.percent,
        progress.done_units,
        progress.total_units,
        progress.indeterminate,
    ) == expected


def test_succeeded_job_projects_to_complete_even_from_an_earlier_stage() -> None:
    """A stale stage column (e.g. mid-write) cannot undersell a success."""
    progress = derive_job_progress(
        _job(JobStatus.SUCCEEDED, ProductionStage.SPEECH), None, _plan()
    )
    assert progress.stage == "complete"
    assert progress.percent == 100.0
    assert not progress.indeterminate


def test_failed_job_keeps_its_stage_derived_progress() -> None:
    """Failure freezes the bar where the pipeline stopped, for diagnosis."""
    progress = derive_job_progress(
        _job(JobStatus.FAILED, ProductionStage.TRANSLATION),
        _checkpoint(accepted=("t0",)),
        _plan(),
    )
    assert progress.percent == 15.0
    assert progress.indeterminate is False


def test_stale_checkpoint_identities_are_ignored() -> None:
    """Ids the plan no longer contains (post-edit resume) never overcount."""
    progress = derive_job_progress(
        _job(JobStatus.RUNNING, ProductionStage.TRANSLATION),
        _checkpoint(accepted=("t0", "t1", "table-0", "removed-block")),
        _plan(),
    )
    assert progress.done_units == 3
    assert progress.total_units == 3
    assert progress.percent == 45.0


def test_empty_plan_degrades_to_indeterminate_at_the_stage_anchor() -> None:
    """A plan without units has nothing measurable: indeterminate, not 45%."""
    progress = derive_job_progress(
        _job(JobStatus.RUNNING, ProductionStage.TRANSLATION),
        None,
        _plan(translation_units=0, narration_sentences=0),
    )
    assert progress.done_units == 0
    assert progress.total_units == 0
    assert progress.percent == 0.0
    assert progress.indeterminate is True


def test_percent_is_rounded_to_one_decimal() -> None:
    progress = derive_job_progress(
        _job(JobStatus.RUNNING, ProductionStage.SPEECH),
        _checkpoint(accepted=("t0", "t1", "table-0"), synthesized=("s0", "s1", "s2")),
        _plan(),
    )
    # 45 + (3/4)*45 = 78.75 -> 78.8 (half-up display rounding at 1 decimal).
    assert progress.percent == 78.8


def test_payload_shape_matches_the_sse_protocol() -> None:
    progress = derive_job_progress(
        _job(JobStatus.RUNNING, ProductionStage.SPEECH),
        _checkpoint(synthesized=("s0",)),
        _plan(),
    )
    assert progress.to_payload() == {
        "stage": "speech",
        "stage_index": 2,
        "percent": 56.2,
        "done_units": 1,
        "total_units": 4,
        "indeterminate": False,
    }


def test_weight_table_covers_all_eight_stages_in_order() -> None:
    """The constants are the §8.1 table: guards against accidental drift."""
    assert STAGE_ORDER == (
        ProductionStage.QUEUED,
        ProductionStage.TRANSLATION,
        ProductionStage.SPEECH,
        ProductionStage.AUDIO,
        ProductionStage.REVIEW,
        ProductionStage.PACKAGING,
        ProductionStage.PUBLISHING,
        ProductionStage.COMPLETE,
    )
    assert [STAGE_ENTRY_PERCENT[stage] for stage in STAGE_ORDER] == [
        0.0,
        0.0,
        45.0,
        90.0,
        95.0,
        97.0,
        99.0,
        100.0,
    ]
