from __future__ import annotations

from datetime import timedelta
from uuid import uuid4

from engirdle_pc.modules.production.domain.errors import InvalidJobState, JobNotFound
from engirdle_pc.modules.production.domain.models import (
    BuildJob,
    JobStatus,
    PipelineConfig,
    ProductionStage,
)
from engirdle_pc.shared.domain.time import isoformat_utc, utc_now
from engirdle_pc.shared.infrastructure.database.connection import Database


class JobRepository:
    def __init__(self, database: Database) -> None:
        self._database = database

    def create(self, article_id: str, revision: int, config: PipelineConfig) -> BuildJob:
        job_id = str(uuid4())
        created_at = isoformat_utc()
        with self._database.connect() as connection:
            connection.execute(
                """
                INSERT INTO build_jobs(
                    job_id, article_id, revision, status, stage, config_json, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    job_id,
                    article_id,
                    revision,
                    JobStatus.QUEUED.value,
                    ProductionStage.QUEUED.value,
                    config.to_json(),
                    created_at,
                ),
            )
        return self.get(job_id)

    def get(self, job_id: str) -> BuildJob:
        with self._database.connect() as connection:
            row = connection.execute(
                "SELECT * FROM build_jobs WHERE job_id = ?", (job_id,)
            ).fetchone()
            if row is None:
                raise JobNotFound(f"job {job_id} not found")
            return _map_job(row)

    def list_recent(self, limit: int = 50) -> tuple[BuildJob, ...]:
        with self._database.connect() as connection:
            rows = connection.execute(
                "SELECT * FROM build_jobs ORDER BY created_at DESC LIMIT ?", (limit,)
            ).fetchall()
            return tuple(_map_job(row) for row in rows)

    def list_ids_for_article(self, article_id: str) -> tuple[str, ...]:
        with self._database.connect() as connection:
            rows = connection.execute(
                "SELECT job_id FROM build_jobs WHERE article_id = ?", (article_id,)
            ).fetchall()
            return tuple(row["job_id"] for row in rows)

    def delete_for_article(self, article_id: str) -> None:
        with self._database.connect() as connection:
            connection.execute("DELETE FROM build_jobs WHERE article_id = ?", (article_id,))

    def recover_stale(self, lease_seconds: int = 300) -> int:
        threshold = isoformat_utc(utc_now() - timedelta(seconds=lease_seconds))
        with self._database.connect() as connection:
            cursor = connection.execute(
                """
                UPDATE build_jobs
                SET status = ?, stage = ?, error_code = ?, error_message = ?
                WHERE status = ? AND heartbeat_at < ?
                """,
                (
                    JobStatus.QUEUED.value,
                    ProductionStage.QUEUED.value,
                    "lease_expired",
                    "Recovered a job whose worker lease expired",
                    JobStatus.RUNNING.value,
                    threshold,
                ),
            )
            return cursor.rowcount

    def claim_next(self) -> BuildJob | None:
        now = isoformat_utc()
        with self._database.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                """
                SELECT job_id FROM build_jobs
                WHERE status = ? ORDER BY created_at LIMIT 1
                """,
                (JobStatus.QUEUED.value,),
            ).fetchone()
            if row is None:
                return None
            connection.execute(
                """
                UPDATE build_jobs
                SET status = ?, stage = ?, attempts = attempts + 1,
                    started_at = COALESCE(started_at, ?), heartbeat_at = ?,
                    finished_at = NULL, error_code = NULL, error_message = NULL
                WHERE job_id = ?
                """,
                (
                    JobStatus.RUNNING.value,
                    ProductionStage.TRANSLATION.value,
                    now,
                    now,
                    row["job_id"],
                ),
            )
        return self.get(row["job_id"])

    def checkpoint(
        self, job_id: str, stage: ProductionStage, checkpoint_json: str | None = None
    ) -> None:
        with self._database.connect() as connection:
            updated = connection.execute(
                """
                UPDATE build_jobs SET stage = ?, checkpoint_json = ?, heartbeat_at = ?
                WHERE job_id = ? AND status = ?
                """,
                (
                    stage.value,
                    checkpoint_json,
                    isoformat_utc(),
                    job_id,
                    JobStatus.RUNNING.value,
                ),
            ).rowcount
            if updated != 1:
                raise InvalidJobState("only a running job can save a checkpoint")

    def require_review(self, job_id: str) -> None:
        with self._database.connect() as connection:
            updated = connection.execute(
                """
                UPDATE build_jobs SET status = ?, stage = ?, heartbeat_at = ?, finished_at = ?
                WHERE job_id = ? AND status = ?
                """,
                (
                    JobStatus.REVIEW_REQUIRED.value,
                    ProductionStage.REVIEW.value,
                    isoformat_utc(),
                    isoformat_utc(),
                    job_id,
                    JobStatus.RUNNING.value,
                ),
            ).rowcount
            if updated != 1:
                raise InvalidJobState("only a running job can enter review")

    def set_review_stage(self, job_id: str, stage: ProductionStage) -> None:
        if stage not in {ProductionStage.PACKAGING, ProductionStage.PUBLISHING}:
            raise ValueError("review jobs can only enter packaging or publishing")
        with self._database.connect() as connection:
            updated = connection.execute(
                """
                UPDATE build_jobs SET stage = ?, heartbeat_at = ?
                WHERE job_id = ? AND status = ?
                """,
                (
                    stage.value,
                    isoformat_utc(),
                    job_id,
                    JobStatus.REVIEW_REQUIRED.value,
                ),
            ).rowcount
            if updated != 1:
                raise InvalidJobState("only a review job can advance release stages")

    def fail(self, job_id: str, code: str, message: str) -> None:
        with self._database.connect() as connection:
            connection.execute(
                """
                UPDATE build_jobs
                SET status = ?, finished_at = ?, heartbeat_at = ?,
                    error_code = ?, error_message = ?
                WHERE job_id = ?
                """,
                (
                    JobStatus.FAILED.value,
                    isoformat_utc(),
                    isoformat_utc(),
                    code,
                    message[:2000],
                    job_id,
                ),
            )

    def retry(self, job_id: str) -> BuildJob:
        with self._database.connect() as connection:
            updated = connection.execute(
                """
                UPDATE build_jobs SET status = ?, stage = ?, finished_at = NULL
                WHERE job_id = ? AND status IN (?, ?)
                """,
                (
                    JobStatus.QUEUED.value,
                    ProductionStage.QUEUED.value,
                    job_id,
                    JobStatus.FAILED.value,
                    JobStatus.REVIEW_REQUIRED.value,
                ),
            ).rowcount
            if updated != 1:
                raise InvalidJobState("only failed or review jobs can be retried")
        return self.get(job_id)

    def mark_succeeded(self, job_id: str) -> None:
        with self._database.connect() as connection:
            updated = connection.execute(
                """
                UPDATE build_jobs SET status = ?, stage = ?, finished_at = ?
                WHERE job_id = ? AND status = ?
                """,
                (
                    JobStatus.SUCCEEDED.value,
                    ProductionStage.COMPLETE.value,
                    isoformat_utc(),
                    job_id,
                    JobStatus.REVIEW_REQUIRED.value,
                ),
            ).rowcount
            if updated != 1:
                raise InvalidJobState("only a reviewed job can succeed")


def _map_job(row: object) -> BuildJob:
    return BuildJob(
        job_id=row["job_id"],  # type: ignore[index]
        article_id=row["article_id"],  # type: ignore[index]
        revision=row["revision"],  # type: ignore[index]
        status=JobStatus(row["status"]),  # type: ignore[index]
        stage=ProductionStage(row["stage"]),  # type: ignore[index]
        attempts=row["attempts"],  # type: ignore[index]
        config=PipelineConfig.from_json(row["config_json"]),  # type: ignore[index]
        checkpoint_json=row["checkpoint_json"],  # type: ignore[index]
        created_at=row["created_at"],  # type: ignore[index]
        started_at=row["started_at"],  # type: ignore[index]
        heartbeat_at=row["heartbeat_at"],  # type: ignore[index]
        finished_at=row["finished_at"],  # type: ignore[index]
        error_code=row["error_code"],  # type: ignore[index]
        error_message=row["error_message"],  # type: ignore[index]
    )
