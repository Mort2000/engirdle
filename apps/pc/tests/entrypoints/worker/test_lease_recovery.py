from pathlib import Path

import pytest

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.modules.content.public import ArticleRevision, Block, NewArticle
from engirdle_pc.modules.translation.infrastructure.stub_adapter import StubTranslationAdapter
from engirdle_pc.modules.translation.public import TranslationBatch
from engirdle_pc.shared.infrastructure.runtime import UuidIdentifierGenerator


class CrashOnceTranslator:
    name = "crash-once-stub"
    provider = "stub-deepseek"
    endpoint = "stub://crash-once"
    model = "deepseek-v4-flash-stub"

    def __init__(self) -> None:
        self._delegate = StubTranslationAdapter(UuidIdentifierGenerator())
        self._crashed = False

    def begin(self, revision: ArticleRevision) -> str:
        return self._delegate.begin(revision)

    def translate_block(
        self, revision: ArticleRevision, block: Block, checkpoint_id: str
    ) -> TranslationBatch:
        if not self._crashed:
            self._crashed = True
            raise SystemExit("simulated worker process crash")
        return self._delegate.translate_block(revision, block, checkpoint_id)


def test_worker_recovers_an_expired_running_lease_and_retries_safely(
    tmp_path: Path,
) -> None:
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"),
        translation_adapter=CrashOnceTranslator(),
    )
    revision = container.content.create(
        NewArticle(
            title="Lease recovery",
            body="Resume this work.",
            author=None,
            source_name=None,
            source_url=None,
            license_name="unknown",
        )
    )
    job = container.production.queue(
        container.content.approve(revision.article_id, revision.revision)
    )

    with pytest.raises(SystemExit):
        container.worker.run_once()
    assert container.production.get(job.job_id).status.value == "running"

    assert container.worker.recover_stale_jobs(lease_seconds=-1) == 1
    assert container.production.get(job.job_id).status.value == "queued"
    assert container.worker.run_once() is True
    recovered = container.production.get(job.job_id)
    assert recovered.status.value == "review_required"
    assert recovered.attempts == 2
