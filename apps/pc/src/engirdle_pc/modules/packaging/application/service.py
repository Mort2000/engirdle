from __future__ import annotations

import json
import os
from collections.abc import Mapping
from uuid import uuid4
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile

from engirdle_pc.modules.audio.public import AudioService, SentenceTiming
from engirdle_pc.modules.content.public import ArticleRevision, ContentService
from engirdle_pc.modules.packaging.application.validator import ReadpackValidator
from engirdle_pc.modules.packaging.domain.models import (
    ArticleBlock,
    ArticlePayload,
    ArticleSentence,
    ArticleSource,
    AttributionArticle,
    AttributionPayload,
    AttributionResource,
    KnownLicense,
    KnownValue,
    Manifest,
    ManifestArticle,
    ManifestAudio,
    PackageArtifact,
    PayloadFile,
    PipelineMetadata,
    ResourceHash,
    TranslationPipeline,
    TtsPipeline,
    UnavailableLicense,
    UnavailableValue,
)
from engirdle_pc.modules.packaging.infrastructure.sqlite_repository import ArtifactRepository
from engirdle_pc.modules.production.public import BuildJob, JobStatus
from engirdle_pc.modules.translation.public import TranslationRepository
from engirdle_pc.shared.domain.time import isoformat_utc
from engirdle_pc.shared.infrastructure.hashing import sha256_bytes, sha256_file
from engirdle_pc.shared.infrastructure.workspace import Workspace


class PackagingService:
    def __init__(
        self,
        artifacts: ArtifactRepository,
        content: ContentService,
        translations: TranslationRepository,
        audio: AudioService,
        validator: ReadpackValidator,
        workspace: Workspace,
    ) -> None:
        self._artifacts = artifacts
        self._content = content
        self._translations = translations
        self._audio = audio
        self._validator = validator
        self._workspace = workspace

    def build(self, job: BuildJob) -> PackageArtifact:
        if job.status is not JobStatus.REVIEW_REQUIRED:
            raise ValueError("only a reviewed production job can be packaged")
        revision = self._content.get(job.article_id, job.revision)
        translations = {
            item.sentence_id: item.published_text
            for item in self._translations.list_for_job(job.job_id)
        }
        audio = self._audio.get(job.job_id)
        timings = {timing.sentence_id: timing for timing in audio.timings}
        expected_ids = {
            sentence.sentence_id
            for block in revision.blocks
            for sentence in block.sentences
        }
        if set(translations) != expected_ids or set(timings) != expected_ids:
            raise ValueError("reviewed translation and audio IDs must match the frozen structure")

        artifact_revision = self._artifacts.next_artifact_revision(
            job.article_id, job.revision
        )
        package_id = str(uuid4())
        created_at = isoformat_utc()
        article_payload = _article_payload(revision, translations, timings)
        attribution_payload = _attribution_payload(revision, job, audio.encoder_version)
        article_bytes = _json_bytes(article_payload)
        attribution_bytes = _json_bytes(attribution_payload)
        audio_bytes = audio.path.read_bytes()
        files = [
            _payload_file("article.json", "application/json", article_bytes),
            _payload_file("attribution.json", "application/json", attribution_bytes),
            _payload_file("audio/article.m4a", "audio/mp4", audio_bytes),
        ]
        manifest = Manifest(
            package_id=package_id,
            created_at=created_at,
            article=ManifestArticle(
                id=job.article_id,
                revision=job.revision,
                artifact_revision=artifact_revision,
            ),
            files=files,
            audio=ManifestAudio(duration_ms=audio.duration_ms),
            pipeline=PipelineMetadata(
                version=job.config.pipeline_version,
                segmenter=job.config.segmenter,
                translation=TranslationPipeline(
                    provider=job.config.translation_provider,
                    endpoint=job.config.translation_endpoint,
                    model=job.config.translation_model,
                    thinking=job.config.translation_thinking,
                    reasoning_effort=job.config.translation_reasoning_effort,
                    prompt=job.config.translation_prompt,
                ),
                tts=TtsPipeline(
                    custom_voice_model=job.config.custom_voice_model,
                    base_model=job.config.base_model,
                    voice_profile=job.config.voice_profile,
                    anchor_sha256=job.config.anchor_sha256,
                    generation=job.config.speech_generation,
                ),
            ),
        )
        manifest_bytes = _json_bytes(manifest)
        artifact_dir = self._workspace.artifact_dir(
            job.article_id, job.revision, artifact_revision
        )
        artifact_dir.mkdir(parents=True, exist_ok=True)
        opaque_name = f"{package_id}.readpack"
        final_path = artifact_dir / opaque_name
        temporary_path = artifact_dir / f".{opaque_name}.tmp"
        with ZipFile(temporary_path, "w") as archive:
            archive.writestr("manifest.json", manifest_bytes, compress_type=ZIP_DEFLATED)
            archive.writestr("article.json", article_bytes, compress_type=ZIP_DEFLATED)
            archive.writestr("attribution.json", attribution_bytes, compress_type=ZIP_DEFLATED)
            archive.writestr("audio/article.m4a", audio_bytes, compress_type=ZIP_STORED)
        self._validator.validate(temporary_path)
        os.replace(temporary_path, final_path)
        self._validator.validate(final_path)
        artifact = PackageArtifact(
            package_id=package_id,
            article_id=job.article_id,
            revision=job.revision,
            artifact_revision=artifact_revision,
            job_id=job.job_id,
            opaque_name=opaque_name,
            path=final_path,
            size=final_path.stat().st_size,
            sha256=sha256_file(final_path),
            state="validated",
            created_at=created_at,
        )
        self._artifacts.insert(artifact)
        return artifact


def _article_payload(
    revision: ArticleRevision,
    translations: Mapping[str, str],
    timings: Mapping[str, SentenceTiming],
) -> ArticlePayload:
    return ArticlePayload(
        article_id=revision.article_id,
        revision=revision.revision,
        title=revision.title,
        source=ArticleSource(
            display_name=revision.source.display_name,
            url=revision.source.url,
            author=revision.source.author,
        ),
        source_sha256=revision.source_sha256,
        normalized_sha256=revision.normalized_sha256,
        structure_sha256=revision.structure_sha256,
        blocks=[
            ArticleBlock(
                block_id=block.block_id,
                kind=block.kind.value,
                order=block.order,
                sentences=[
                    ArticleSentence(
                        sentence_id=sentence.sentence_id,
                        order=sentence.order,
                        text=sentence.text,
                        translation_zh=translations[sentence.sentence_id],
                        audio_start_sample=timings[sentence.sentence_id].start_sample,
                        audio_end_sample=timings[sentence.sentence_id].end_sample,
                        audio_start_ms=timings[sentence.sentence_id].start_ms,
                        audio_end_ms=timings[sentence.sentence_id].end_ms,
                    )
                    for sentence in block.sentences
                ],
            )
            for block in revision.blocks
        ],
    )


def _attribution_payload(
    revision: ArticleRevision, job: BuildJob, encoder_version: str
) -> AttributionPayload:
    source_value = revision.source.url or revision.source.display_name
    article_source = (
        KnownValue(value=source_value)
        if source_value
        else UnavailableValue(status="unknown")
    )
    article_license = (
        KnownLicense(name=revision.source.license_name)
        if revision.source.license_name != "unknown"
        else UnavailableLicense(status="unknown")
    )
    no_modifications = UnavailableValue(status="not_applicable")
    unknown_license = UnavailableLicense(status="unknown")
    return AttributionPayload(
        article=AttributionArticle(id=revision.article_id, revision=revision.revision),
        resources=[
            AttributionResource(
                resource_id="article-source",
                kind="article_source",
                role="content",
                name=revision.source.display_name or revision.title,
                source=article_source,
                version=UnavailableValue(status="not_applicable"),
                license=article_license,
                modifications=KnownValue(value="Normalized and segmented for offline reading"),
                hashes=[ResourceHash(value=revision.source_sha256)],
            ),
            AttributionResource(
                resource_id="translation-service",
                kind="translation_service",
                role="translation",
                name="DeepSeek-compatible translation adapter",
                source=KnownValue(value="Local deterministic stub; no remote request was made"),
                version=KnownValue(value=job.config.translation_model),
                license=UnavailableLicense(status="not_applicable"),
                modifications=no_modifications,
                hashes=[],
                notes="MVP integration stub output; replace the adapter before content release.",
            ),
            AttributionResource(
                resource_id="tts-custom-voice-model",
                kind="tts_model",
                role="custom_voice",
                name="Qwen3-TTS CustomVoice",
                source=KnownValue(value="Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"),
                version=KnownValue(value=job.config.custom_voice_model),
                license=unknown_license,
                modifications=no_modifications,
                hashes=[],
                notes="Model identity stub; no checkpoint was loaded.",
            ),
            AttributionResource(
                resource_id="tts-base-model",
                kind="tts_model",
                role="base_voice_clone",
                name="Qwen3-TTS Base",
                source=KnownValue(value="Qwen/Qwen3-TTS-12Hz-1.7B-Base"),
                version=KnownValue(value=job.config.base_model),
                license=unknown_license,
                modifications=no_modifications,
                hashes=[],
                notes="Audible deterministic tone stub; no checkpoint was loaded.",
            ),
            AttributionResource(
                resource_id="voice-profile",
                kind="voice_profile",
                role="narration",
                name="Deterministic stub voice profile",
                source=KnownValue(value="Generated locally for pipeline validation"),
                version=KnownValue(value=job.config.voice_profile),
                license=unknown_license,
                modifications=no_modifications,
                hashes=[ResourceHash(value=job.config.anchor_sha256)],
            ),
            AttributionResource(
                resource_id="engirdle-pipeline",
                kind="software_dependency",
                role="pipeline",
                name="Engirdle PC pipeline",
                source=KnownValue(value="Engirdle repository"),
                version=KnownValue(value=job.config.pipeline_version),
                license=unknown_license,
                modifications=no_modifications,
                hashes=[],
            ),
            AttributionResource(
                resource_id="audio-encoder",
                kind="software_dependency",
                role="audio_encoder",
                name="FFmpeg",
                source=KnownValue(value="https://ffmpeg.org/"),
                version=KnownValue(value=encoder_version),
                license=unknown_license,
                modifications=no_modifications,
                hashes=[],
            ),
        ],
    )


def _payload_file(path: str, media_type: str, content: bytes) -> PayloadFile:
    return PayloadFile(
        path=path,
        size=len(content),
        sha256=sha256_bytes(content),
        media_type=media_type,
    )


def _json_bytes(model: object) -> bytes:
    payload = model.model_dump(mode="json", exclude_none=True)  # type: ignore[attr-defined]
    if isinstance(model, ArticlePayload):
        # The v1 contract requires all three source display keys, with JSON null
        # representing an explicitly unavailable value.
        payload["source"] = model.source.model_dump(mode="json", exclude_none=False)
    return (json.dumps(payload, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
