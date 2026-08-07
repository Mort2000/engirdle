from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass

from engirdle_pc.modules.audio.public import AudioReview
from engirdle_pc.modules.content.public import ArticleRevision
from engirdle_pc.modules.packaging.public import PackageArtifact
from engirdle_pc.modules.production.public import BuildJob
from engirdle_pc.modules.publishing.public import PublishedPackage, PublisherStatus
from engirdle_pc.modules.translation.public import ReviewedTranslation


@dataclass(frozen=True)
class TextValueView:
    value: str


@dataclass(frozen=True)
class SourceView:
    author: str | None
    display_name: str | None
    url: str | None
    license_name: str


@dataclass(frozen=True)
class ArticleView:
    article_id: str
    revision: int
    title: str
    raw_text: str
    status: TextValueView
    source: SourceView
    blocks: tuple[str, ...]


@dataclass(frozen=True)
class JobConfigView:
    translation_adapter: str
    speech_adapter: str


@dataclass(frozen=True)
class JobView:
    job_id: str
    article_id: str
    status: TextValueView
    stage: TextValueView
    attempts: int
    config: JobConfigView
    error_code: str | None
    error_message: str | None


@dataclass(frozen=True)
class TranslationView:
    sentence_id: str
    source_text: str
    published_text: str


@dataclass(frozen=True)
class SentenceAudioView:
    sentence_id: str
    source_text: str
    start_ms: int
    end_ms: int


@dataclass(frozen=True)
class AudioChecksView:
    missing_sentence_ids: tuple[str, ...]
    zero_duration_sentence_ids: tuple[str, ...]
    abnormal_duration_sentence_ids: tuple[str, ...]


@dataclass(frozen=True)
class AudioOutputView:
    duration_ms: int
    encoder_version: str
    timings: tuple[SentenceAudioView, ...]


@dataclass(frozen=True)
class AudioReviewView:
    output: AudioOutputView
    checks: AudioChecksView


@dataclass(frozen=True)
class PublishedView:
    title: str
    revision: int
    artifact_revision: int
    size: int
    sha256: str


@dataclass(frozen=True)
class ArtifactView:
    package_id: str
    article_id: str
    revision: int
    artifact_revision: int
    size: int
    state: str


@dataclass(frozen=True)
class PublisherView:
    running: bool
    binding_url: str
    started_at: str | None
    pid: int | None


def article_view(article: ArticleRevision) -> ArticleView:
    return ArticleView(
        article_id=article.article_id,
        revision=article.revision,
        title=article.title,
        raw_text=article.raw_text,
        status=TextValueView(article.status.value),
        source=SourceView(
            author=article.source.author,
            display_name=article.source.display_name,
            url=article.source.url,
            license_name=article.source.license_name,
        ),
        blocks=tuple(block.block_id for block in article.blocks),
    )


def job_view(job: BuildJob) -> JobView:
    return JobView(
        job_id=job.job_id,
        article_id=job.article_id,
        status=TextValueView(job.status.value),
        stage=TextValueView(job.stage.value),
        attempts=job.attempts,
        config=JobConfigView(
            translation_adapter=job.config.translation_adapter,
            speech_adapter=job.config.speech_adapter,
        ),
        error_code=job.error_code,
        error_message=job.error_message,
    )


def translation_views(
    translations: tuple[ReviewedTranslation, ...],
    source_by_id: Mapping[str, str],
) -> tuple[TranslationView, ...]:
    return tuple(
        TranslationView(
            sentence_id=item.sentence_id,
            source_text=source_by_id[item.sentence_id],
            published_text=item.published_text,
        )
        for item in translations
    )


def audio_review_view(
    review: AudioReview, source_by_id: Mapping[str, str]
) -> AudioReviewView:
    return AudioReviewView(
        output=AudioOutputView(
            duration_ms=review.output.duration_ms,
            encoder_version=review.output.encoder_version,
            timings=tuple(
                SentenceAudioView(
                    sentence_id=timing.sentence_id,
                    source_text=source_by_id[timing.sentence_id],
                    start_ms=timing.start_ms,
                    end_ms=timing.end_ms,
                )
                for timing in review.output.timings
            ),
        ),
        checks=AudioChecksView(
            missing_sentence_ids=review.checks.missing_sentence_ids,
            zero_duration_sentence_ids=review.checks.zero_duration_sentence_ids,
            abnormal_duration_sentence_ids=(
                review.checks.abnormal_duration_sentence_ids
            ),
        ),
    )


def published_view(package: PublishedPackage) -> PublishedView:
    return PublishedView(
        title=package.title,
        revision=package.revision,
        artifact_revision=package.artifact_revision,
        size=package.size,
        sha256=package.sha256,
    )


def artifact_view(artifact: PackageArtifact) -> ArtifactView:
    return ArtifactView(
        package_id=artifact.package_id,
        article_id=artifact.article_id,
        revision=artifact.revision,
        artifact_revision=artifact.artifact_revision,
        size=artifact.size,
        state=artifact.state,
    )


def publisher_view(status: PublisherStatus) -> PublisherView:
    return PublisherView(
        running=status.running,
        binding_url=status.binding_url,
        started_at=status.started_at,
        pid=status.pid,
    )
