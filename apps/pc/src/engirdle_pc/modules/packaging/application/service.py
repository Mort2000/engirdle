from __future__ import annotations

import json
from collections.abc import Mapping

from engirdle_pc.modules.audio.public import AudioService, SentenceTiming
from engirdle_pc.modules.content.public import (
    ArticleRevision,
    CodeBlock,
    ContentService,
    DividerBlock,
    InlineRun,
    ProcessingPlan,
    TableBlock,
    TableCell,
    TextBlock,
)
from engirdle_pc.modules.content.public import (
    Block as RenderBlock,
)
from engirdle_pc.modules.packaging.application.contracts import (
    MARKDOWN_BLOCKS_CAPABILITY,
    ArticleBlock,
    ArticlePayload,
    ArticleRun,
    ArticleSentence,
    ArticleSource,
    ArticleTableCell,
    AttributionArticle,
    AttributionPayload,
    AttributionResource,
    AudioEncodingPipeline,
    KnownLicense,
    KnownValue,
    Manifest,
    ManifestArticle,
    ManifestAudio,
    PayloadFile,
    PipelineMetadata,
    ResourceHash,
    TranslationPipeline,
    TtsPipeline,
    UnavailableLicense,
    UnavailableValue,
)
from engirdle_pc.modules.packaging.application.models import (
    PackageArtifact,
    PackageContents,
)
from engirdle_pc.modules.packaging.application.ports import (
    ArtifactStore,
    PackageWriter,
)
from engirdle_pc.modules.production.public import BuildJob, JobStatus
from engirdle_pc.modules.translation.public import TableUnitTranslation, TranslationService
from engirdle_pc.shared.application.runtime import Clock, IdentifierGenerator
from engirdle_pc.shared.domain.hashing import sha256_bytes
from engirdle_pc.shared.domain.time import isoformat_utc


class PackagingService:
    def __init__(
        self,
        artifacts: ArtifactStore,
        content: ContentService,
        translations: TranslationService,
        audio: AudioService,
        writer: PackageWriter,
        clock: Clock,
        identifiers: IdentifierGenerator,
    ) -> None:
        self._artifacts = artifacts
        self._content = content
        self._translations = translations
        self._audio = audio
        self._writer = writer
        self._clock = clock
        self._identifiers = identifiers

    def build(self, job: BuildJob) -> PackageArtifact:
        if job.status is not JobStatus.REVIEW_REQUIRED:
            raise ValueError("only a reviewed production job can be packaged")
        revision = self._content.get(job.article_id, job.revision)
        plan = self._content.processing_plan(job.article_id, job.revision)
        sentence_translations = self._translations.sentence_translations(job.job_id)
        table_translations = self._translations.table_translations(job.job_id)
        audio = self._audio.get(job.job_id)
        timings = {timing.sentence_id: timing for timing in audio.timings}
        # Split validation sets (design §8.7): the packager verifies results
        # against the plan's projections; it never re-decides eligibility.
        expected_sentence_ids = set(plan.narration.sentence_ids)
        expected_table_ids = {
            unit.block_id for unit in plan.translation.table_units
        }
        if set(sentence_translations) != expected_sentence_ids:
            raise ValueError(
                "reviewed sentence translations must match the narratable sentences"
            )
        if set(table_translations) != expected_table_ids:
            raise ValueError(
                "reviewed table translations must match the table blocks"
            )
        if set(timings) != expected_sentence_ids:
            raise ValueError(
                "audio timing IDs must match the narration plan"
            )
        unprocessed_ids = {
            block.block_id
            for block in plan.render.blocks
            if isinstance(block, (CodeBlock, DividerBlock))
        }
        leaked = unprocessed_ids & (set(sentence_translations) | set(timings))
        if leaked:
            raise ValueError(
                f"non-processing blocks must not carry results: {sorted(leaked)}"
            )

        artifact_revision = self._artifacts.next_artifact_revision(
            job.article_id, job.revision
        )
        package_id = self._identifiers.new()
        created_at = isoformat_utc(self._clock.now())
        article_payload = _article_payload(
            revision, plan, sentence_translations, table_translations, timings
        )
        attribution_payload = _attribution_payload(revision, job, audio.encoder_version)
        article_bytes = _json_bytes(article_payload)
        attribution_bytes = _json_bytes(attribution_payload)
        audio_metadata = self._writer.describe_input(audio.path)
        files = [
            _payload_file("article.json", "application/json", article_bytes),
            _payload_file("attribution.json", "application/json", attribution_bytes),
            PayloadFile(
                path="audio/article.m4a",
                size=audio_metadata.size,
                sha256=audio_metadata.sha256,
                media_type="audio/mp4",
            ),
        ]
        manifest = Manifest(
            package_id=package_id,
            created_at=created_at,
            format_version="1.1",
            required_capabilities=[MARKDOWN_BLOCKS_CAPABILITY],
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
                parser=job.config.markdown_parser,
                translation=TranslationPipeline(
                    provider=job.config.translation_provider,
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
                audio_encoding=AudioEncodingPipeline(
                    codec="aac-lc",
                    bitrate_kbps=job.config.audio_bitrate_kbps,
                    sample_rate_hz=audio.sample_rate_hz,
                    channels=audio.channels,
                    loudness_target_lufs=job.config.audio_loudness_target_lufs,
                    true_peak_dbfs=job.config.audio_true_peak_dbfs,
                    loudness_range_lu=job.config.audio_loudness_range_lu,
                ),
            ),
        )
        manifest_bytes = _json_bytes(manifest)
        opaque_name = f"{package_id}.readpack"
        stored = self._writer.write(
            job.article_id,
            job.revision,
            artifact_revision,
            opaque_name,
            PackageContents(
                manifest=manifest_bytes,
                article=article_bytes,
                attribution=attribution_bytes,
                audio_path=audio.path,
            ),
        )
        artifact = PackageArtifact(
            package_id=package_id,
            article_id=job.article_id,
            revision=job.revision,
            artifact_revision=artifact_revision,
            job_id=job.job_id,
            opaque_name=opaque_name,
            path=stored.path,
            size=stored.size,
            sha256=stored.sha256,
            state="validated",
            created_at=created_at,
        )
        self._artifacts.insert(artifact)
        return artifact

    def mark_published(self, package_id: str) -> None:
        self._artifacts.mark_published(package_id)

    def get_verified(self, package_id: str) -> PackageArtifact:
        artifact = self._artifacts.get(package_id)
        actual = self._writer.verify(artifact.path)
        if actual.size != artifact.size or actual.sha256 != artifact.sha256:
            raise ValueError("stored package metadata does not match its bytes")
        return artifact

    def list_for_article(self, article_id: str) -> tuple[PackageArtifact, ...]:
        return self._artifacts.list_for_article(article_id)

    def delete_for_article(self, article_id: str) -> None:
        self._artifacts.delete_for_article(article_id)


def _article_payload(
    revision: ArticleRevision,
    plan: ProcessingPlan,
    sentence_translations: Mapping[str, str],
    table_translations: Mapping[str, TableUnitTranslation],
    timings: Mapping[str, SentenceTiming],
) -> ArticlePayload:
    return ArticlePayload(
        format_version="1.1",
        required_capabilities=[MARKDOWN_BLOCKS_CAPABILITY],
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
            _block_payload(
                block,
                sentence_translations,
                table_translations,
                timings,
            )
            for block in plan.render.blocks
        ],
    )


def _block_payload(
    block: RenderBlock,
    sentence_translations: Mapping[str, str],
    table_translations: Mapping[str, TableUnitTranslation],
    timings: Mapping[str, SentenceTiming],
) -> ArticleBlock:
    if isinstance(block, TextBlock):
        return ArticleBlock(
            block_id=block.block_id,
            kind=block.kind.value,
            order=block.order,
            level=block.heading_level,
            list_kind=(
                block.list_kind.value if block.list_kind is not None else None
            ),
            list_depth=block.list_depth,
            list_ordinal=block.list_ordinal,
            quote_depth=block.quote_depth,
            sentences=[
                ArticleSentence(
                    sentence_id=sentence.sentence_id,
                    order=sentence.order,
                    text=sentence.text,
                    translation_zh=sentence_translations[sentence.sentence_id],
                    audio_start_sample=timings[sentence.sentence_id].start_sample,
                    audio_end_sample=timings[sentence.sentence_id].end_sample,
                    audio_start_ms=timings[sentence.sentence_id].start_ms,
                    audio_end_ms=timings[sentence.sentence_id].end_ms,
                    runs=[_run_payload(run) for run in sentence.runs],
                )
                for sentence in block.sentences
            ],
        )
    if isinstance(block, TableBlock):
        translation = table_translations[block.block_id]
        translated_by_cell = {
            cell.cell_id: cell.text_zh for cell in translation.cells
        }
        cells = [*block.header, *(c for row in block.rows for c in row)]
        return ArticleBlock(
            block_id=block.block_id,
            kind="table",
            order=block.order,
            alignments=[alignment.value for alignment in block.alignments],
            header=[_cell_payload(cell) for cell in block.header],
            rows=[[_cell_payload(cell) for cell in row] for row in block.rows],
            translation_zh={
                cell.cell_id: translated_by_cell[cell.cell_id] for cell in cells
            },
        )
    if isinstance(block, CodeBlock):
        return ArticleBlock(
            block_id=block.block_id,
            kind="code",
            order=block.order,
            language=block.language,
            code=block.code,
        )
    return ArticleBlock(block_id=block.block_id, kind="divider", order=block.order)


def _cell_payload(cell: TableCell) -> ArticleTableCell:
    return ArticleTableCell(
        cell_id=cell.cell_id,
        text=cell.plain_text,
        runs=[_run_payload(run) for run in cell.runs],
    )


def _run_payload(run: InlineRun) -> ArticleRun:
    return ArticleRun(kind=run.kind.value, text=run.text, href=run.href)


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


# Fields the wire schema REQUIRES per kind even when empty: a header-only
# table legitimately serializes "rows": [], and dropping the key would make a
# PC-built package fail its own schema (the empty value is the value).
_REQUIRED_WHEN_EMPTY: dict[str, set[str]] = {
    "table": {"alignments", "header", "rows"},
}


def _strip_absent_fields(block: object) -> object:
    """Drop absent-valued fields from one wire block so it stays kind-specific.

    The block union's optional fields default to empty collections (or 0 for
    quote_depth/list_depth); emitting them for other kinds would put another
    kind's payload on the wire and collide with the discriminated-union
    schema rules. Nothing semantic is lost: absence equals the default for
    every such field. Fields a kind REQUIRES stay even when empty (a
    header-only table keeps "rows": []). Applied ONLY to article blocks —
    attribution resources legitimately carry required-but-empty arrays such
    as 'hashes'.
    """
    if not isinstance(block, dict):
        return block
    keep_when_empty = _REQUIRED_WHEN_EMPTY.get(str(block.get("kind")), set())
    result: dict[str, object] = {}
    for key, item in block.items():
        if item in ([], {}) and key not in keep_when_empty:
            continue
        if key in {"quote_depth", "list_depth"} and item == 0:
            continue
        result[key] = (
            [_strip_absent_fields(child) for child in item]
            if isinstance(item, list)
            else item
        )
    return result


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
        payload["blocks"] = [_strip_absent_fields(block) for block in payload["blocks"]]
    return (json.dumps(payload, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
