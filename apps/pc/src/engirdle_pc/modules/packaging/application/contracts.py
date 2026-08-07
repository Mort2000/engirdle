from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict


class ContractModel(BaseModel):
    model_config = ConfigDict(extra="allow")


class PayloadFile(ContractModel):
    path: str
    size: int
    sha256: str
    media_type: str


class ManifestArticle(ContractModel):
    id: str
    revision: int
    artifact_revision: int


class ManifestAudio(ContractModel):
    path: Literal["audio/article.m4a"] = "audio/article.m4a"
    codec: Literal["aac-lc"] = "aac-lc"
    sample_rate_hz: Literal[24000] = 24000
    channels: Literal[1] = 1
    duration_ms: int


class TranslationPipeline(ContractModel):
    provider: str
    model: str
    thinking: str
    reasoning_effort: str
    prompt: str


class TtsPipeline(ContractModel):
    custom_voice_model: str
    base_model: str
    voice_profile: str
    anchor_sha256: str
    generation: str


class AudioEncodingPipeline(ContractModel):
    codec: Literal["aac-lc"] = "aac-lc"
    bitrate_kbps: int
    sample_rate_hz: int
    channels: int
    loudness_target_lufs: float
    true_peak_dbfs: float
    loudness_range_lu: float


class PipelineMetadata(ContractModel):
    version: str
    segmenter: str
    translation: TranslationPipeline
    tts: TtsPipeline
    audio_encoding: AudioEncodingPipeline


class Manifest(ContractModel):
    format: Literal["readpack"] = "readpack"
    format_version: Literal["1.0"] = "1.0"
    required_capabilities: list[str] = []
    package_id: str
    created_at: str
    article: ManifestArticle
    files: list[PayloadFile]
    audio: ManifestAudio
    pipeline: PipelineMetadata


class ArticleSource(ContractModel):
    display_name: str | None
    url: str | None
    author: str | None


class ArticleSentence(ContractModel):
    sentence_id: str
    order: int
    text: str
    translation_zh: str
    audio_start_sample: int
    audio_end_sample: int
    audio_start_ms: int
    audio_end_ms: int


class ArticleBlock(ContractModel):
    block_id: str
    kind: str
    order: int
    sentences: list[ArticleSentence]


class ArticlePayload(ContractModel):
    format: Literal["readpack-article"] = "readpack-article"
    format_version: Literal["1.0"] = "1.0"
    article_id: str
    revision: int
    title: str
    source: ArticleSource
    source_sha256: str
    normalized_sha256: str
    structure_sha256: str
    blocks: list[ArticleBlock]


class KnownValue(ContractModel):
    status: Literal["known"] = "known"
    value: str


class UnavailableValue(ContractModel):
    status: Literal["unknown", "not_applicable"]


class KnownLicense(ContractModel):
    status: Literal["known"] = "known"
    name: str
    url: str | None = None


class UnavailableLicense(ContractModel):
    status: Literal["unknown", "not_applicable"]


class ResourceHash(ContractModel):
    algorithm: Literal["sha256"] = "sha256"
    value: str


class AttributionResource(ContractModel):
    resource_id: str
    kind: str
    role: str
    name: str
    source: KnownValue | UnavailableValue
    version: KnownValue | UnavailableValue
    license: KnownLicense | UnavailableLicense
    modifications: KnownValue | UnavailableValue
    hashes: list[ResourceHash]
    notes: str | None = None


class AttributionArticle(ContractModel):
    id: str
    revision: int


class AttributionPayload(ContractModel):
    format: Literal["readpack-attribution"] = "readpack-attribution"
    format_version: Literal["1.0"] = "1.0"
    article: AttributionArticle
    resources: list[AttributionResource]
