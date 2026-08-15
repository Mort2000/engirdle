from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass

from engirdle_pc.modules.audio.public import AudioReview
from engirdle_pc.modules.content.public import ArticleRevision
from engirdle_pc.modules.packaging.public import PackageArtifact
from engirdle_pc.modules.production.public import BuildJob
from engirdle_pc.modules.publishing.public import PublishedPackage, PublisherStatus
from engirdle_pc.modules.speech.public import AnchorBatch, VoiceProfile
from engirdle_pc.modules.translation.public import (
    ReviewedUnit,
    SentenceUnitTranslation,
    TableUnitTranslation,
    UnitKind,
)


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
class TableTranslationCellView:
    cell_id: str
    text_zh: str


@dataclass(frozen=True)
class TableTranslationView:
    block_id: str
    cells: tuple[TableTranslationCellView, ...]


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


@dataclass(frozen=True)
class VoiceProfileView:
    voice_profile_id: str
    revision: int
    speaker: str
    instruct: str
    anchor_text: str
    anchor_sha256: str
    duration_ms: int
    seed: int
    custom_voice_model: str
    is_active: bool
    confirmed_at: str
    audio_url: str


@dataclass(frozen=True)
class AnchorCandidateView:
    candidate_index: int
    seed: int
    duration_ms: int
    sha256: str
    audio_url: str


@dataclass(frozen=True)
class AnchorBatchView:
    batch_id: str
    speaker: str
    instruct: str
    anchor_text: str
    created_at: str
    candidates: tuple[AnchorCandidateView, ...]


def voice_profile_view(profile: VoiceProfile) -> VoiceProfileView:
    return VoiceProfileView(
        voice_profile_id=profile.voice_profile_id,
        revision=profile.revision,
        speaker=profile.speaker,
        instruct=profile.instruct,
        anchor_text=profile.anchor_text,
        anchor_sha256=profile.anchor_sha256,
        duration_ms=profile.duration_ms,
        seed=profile.seed,
        custom_voice_model=profile.custom_voice_model,
        is_active=profile.is_active,
        confirmed_at=profile.confirmed_at,
        audio_url=(
            f"/api/voices/profiles/{profile.voice_profile_id}/{profile.revision}/audio"
        ),
    )


def anchor_batch_view(batch: AnchorBatch) -> AnchorBatchView:
    return AnchorBatchView(
        batch_id=batch.batch_id,
        speaker=batch.speaker,
        instruct=batch.instruct,
        anchor_text=batch.anchor_text,
        created_at=batch.created_at,
        candidates=tuple(
            AnchorCandidateView(
                candidate_index=candidate.candidate_index,
                seed=candidate.seed,
                duration_ms=candidate.duration_ms,
                sha256=candidate.sha256,
                audio_url=(
                    f"/api/voices/batches/{batch.batch_id}"
                    f"/audio/{candidate.candidate_index}"
                ),
            )
            for candidate in batch.candidates
        ),
    )


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
    translations: tuple[ReviewedUnit, ...],
    source_by_id: Mapping[str, str],
) -> tuple[TranslationView, ...]:
    """Flatten sentence units for the review list; tables are separate views."""
    views: list[TranslationView] = []
    for unit in translations:
        published = unit.published
        if unit.unit_kind is UnitKind.SENTENCE and isinstance(
            published, SentenceUnitTranslation
        ):
            for entry in published.translations:
                views.append(
                    TranslationView(
                        sentence_id=entry.sentence_id,
                        source_text=source_by_id.get(entry.sentence_id, ""),
                        published_text=entry.text_zh,
                    )
                )
    return tuple(views)


def table_translation_views(
    translations: tuple[ReviewedUnit, ...],
) -> tuple[TableTranslationView, ...]:
    views: list[TableTranslationView] = []
    for unit in translations:
        published = unit.published
        if unit.unit_kind is UnitKind.TABLE and isinstance(
            published, TableUnitTranslation
        ):
            views.append(
                TableTranslationView(
                    block_id=unit.unit_id,
                    cells=tuple(
                        TableTranslationCellView(
                            cell_id=cell.cell_id, text_zh=cell.text_zh
                        )
                        for cell in published.cells
                    ),
                )
            )
    return tuple(views)


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
