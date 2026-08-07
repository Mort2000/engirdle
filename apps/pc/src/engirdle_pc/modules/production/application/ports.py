from __future__ import annotations

from pathlib import Path
from typing import Protocol

from engirdle_pc.modules.production.domain.models import (
    BuildJob,
    PipelineConfig,
    ProductionStage,
)


class JobStore(Protocol):
    def create(self, article_id: str, revision: int, config: PipelineConfig) -> BuildJob: ...

    def get(self, job_id: str) -> BuildJob: ...

    def list_recent(self, limit: int = 50) -> tuple[BuildJob, ...]: ...

    def list_ids_for_article(self, article_id: str) -> tuple[str, ...]: ...

    def delete_for_article(self, article_id: str) -> None: ...

    def recover_stale(self, lease_seconds: int = 300) -> int: ...

    def claim_next(self) -> BuildJob | None: ...

    def checkpoint(
        self,
        job_id: str,
        stage: ProductionStage,
        checkpoint_json: str | None = None,
    ) -> None: ...

    def require_review(self, job_id: str) -> None: ...

    def set_review_stage(self, job_id: str, stage: ProductionStage) -> None: ...

    def fail(self, job_id: str, code: str, message: str) -> None: ...

    def retry(self, job_id: str) -> BuildJob: ...

    def mark_succeeded(self, job_id: str) -> None: ...


class ProductionWorkspace(Protocol):
    def job_dir(self, job_id: str) -> Path: ...
