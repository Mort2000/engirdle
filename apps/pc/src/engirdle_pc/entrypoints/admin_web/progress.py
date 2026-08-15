"""Derived job progress for the admin UI (design §8.1).

Progress is a pure projection of already-persisted state — ``BuildJob``
stage/status, the worker's ``ProductionCheckpoint`` and the unit totals of
the frozen ``ProcessingPlan``. Nothing here writes domain state or invents
new persistence; the weights are display constants, centralised so the
visual scale can be tuned without touching derivation logic.

Weight table (§8.1) — the value is the cumulative percent reached when a
job ENTERS the stage:

==================  =======================================  ============
stage               in-stage progress                        entry weight
==================  =======================================  ============
queued              indeterminate (waiting for the worker)   0%
translation         accepted translation units / total       0%
speech              synthesized narration units / total      45%
audio               indeterminate (short: mix/encode)        90%
review              fixed 100% (waiting for a human)         95%
packaging           indeterminate (short)                    97%
publishing          indeterminate (short)                    99%
complete            —                                        100%
==================  =======================================  ============

Total percent = entry_weight[stage] + in_stage_fraction *
(entry_weight[next stage] - entry_weight[stage]), rounded to one decimal.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass

from engirdle_pc.modules.content.public import ProcessingPlan
from engirdle_pc.modules.production.public import (
    BuildJob,
    JobStatus,
    ProductionCheckpoint,
    ProductionStage,
)

STAGE_ORDER: tuple[ProductionStage, ...] = (
    ProductionStage.QUEUED,
    ProductionStage.TRANSLATION,
    ProductionStage.SPEECH,
    ProductionStage.AUDIO,
    ProductionStage.REVIEW,
    ProductionStage.PACKAGING,
    ProductionStage.PUBLISHING,
    ProductionStage.COMPLETE,
)
"""The eight pipeline stages in order; the index drives the UI stepper."""

STAGE_ENTRY_PERCENT: Mapping[ProductionStage, float] = {
    ProductionStage.QUEUED: 0.0,
    ProductionStage.TRANSLATION: 0.0,
    ProductionStage.SPEECH: 45.0,
    ProductionStage.AUDIO: 90.0,
    ProductionStage.REVIEW: 95.0,
    ProductionStage.PACKAGING: 97.0,
    ProductionStage.PUBLISHING: 99.0,
    ProductionStage.COMPLETE: 100.0,
}
"""Cumulative display weight when entering each stage (§8.1)."""


@dataclass(frozen=True)
class JobProgress:
    """The derived progress object served over REST and SSE (§8.2)."""

    stage: str
    stage_index: int
    percent: float
    done_units: int | None
    total_units: int | None
    indeterminate: bool

    def to_payload(self) -> dict[str, object]:
        return {
            "stage": self.stage,
            "stage_index": self.stage_index,
            "percent": self.percent,
            "done_units": self.done_units,
            "total_units": self.total_units,
            "indeterminate": self.indeterminate,
        }


def derive_job_progress(
    job: BuildJob,
    checkpoint: ProductionCheckpoint | None,
    plan: ProcessingPlan,
) -> JobProgress:
    """Project a job's persisted state onto the display progress model.

    The checkpoint may be ``None`` before the worker's first write; that
    simply means zero accepted units. A unit-measured stage whose plan has
    no units has nothing measurable to show and degrades to an
    indeterminate bar anchored at the stage's entry weight.
    """
    stage = _effective_stage(job)
    index = STAGE_ORDER.index(stage)
    entry = STAGE_ENTRY_PERCENT[stage]
    next_entry = STAGE_ENTRY_PERCENT[STAGE_ORDER[min(index + 1, len(STAGE_ORDER) - 1)]]

    unit_total, unit_done = _stage_unit_counts(stage, checkpoint, plan)
    if unit_total is None:
        # Stages without unit semantics: queued, audio, packaging,
        # publishing and complete never carry counters; review is determinate
        # at full in-stage progress because it only waits for a human.
        determinate = stage in {ProductionStage.REVIEW, ProductionStage.COMPLETE}
        in_stage = 1.0 if stage is ProductionStage.REVIEW else 0.0
        indeterminate = not determinate
        done: int | None = None
        total: int | None = None
    elif unit_total == 0:
        # A plan without units leaves the stage unmeasurable (§8.1 note).
        in_stage = 0.0
        indeterminate = True
        done, total = 0, 0
    else:
        in_stage = unit_done / unit_total
        indeterminate = False
        done, total = unit_done, unit_total
    percent = round(entry + in_stage * (next_entry - entry), 1)
    return JobProgress(
        stage=stage.value,
        stage_index=index,
        percent=percent,
        done_units=done,
        total_units=total,
        indeterminate=indeterminate,
    )


def _effective_stage(job: BuildJob) -> ProductionStage:
    """Resolve the display stage: a succeeded job is always complete."""
    if job.status is JobStatus.SUCCEEDED:
        return ProductionStage.COMPLETE
    return job.stage


def _stage_unit_counts(
    stage: ProductionStage,
    checkpoint: ProductionCheckpoint | None,
    plan: ProcessingPlan,
) -> tuple[int | None, int]:
    """Done/total units for unit-measured stages; total ``None`` otherwise.

    Checkpoint identities that the plan no longer contains (e.g. after a
    structure edit between runs) are ignored via the intersection, so stale
    ids can never push the fraction above 1.
    """
    if stage is ProductionStage.TRANSLATION:
        unit_ids = set(plan.translation.unit_ids)
        done = len(set(checkpoint.accepted_translation_unit_ids) & unit_ids) if checkpoint else 0
        return len(unit_ids), done
    if stage is ProductionStage.SPEECH:
        sentence_ids = set(plan.narration.sentence_ids)
        done = (
            len(set(checkpoint.synthesized_narration_unit_ids) & sentence_ids)
            if checkpoint
            else 0
        )
        return len(sentence_ids), done
    return None, 0
