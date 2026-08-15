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
    # Markdown parser identity (design §8.1); absent in pre-markdown packages.
    parser: str | None = None
    translation: TranslationPipeline
    tts: TtsPipeline
    audio_encoding: AudioEncodingPipeline


class Manifest(ContractModel):
    format: Literal["readpack"] = "readpack"
    format_version: Literal["1.0", "1.1"] = "1.0"
    required_capabilities: list[str] = []
    package_id: str
    created_at: str
    article: ManifestArticle
    files: list[PayloadFile]
    audio: ManifestAudio
    pipeline: PipelineMetadata


# The capability every markdown-block package must declare (design §9.1). Old
# v1.0-only clients reject it explicitly instead of mis-rendering tables/code.
MARKDOWN_BLOCKS_CAPABILITY = "markdown-blocks"


class ArticleSource(ContractModel):
    display_name: str | None
    url: str | None
    author: str | None


class ArticleRun(ContractModel):
    """One inline run of a v1.1 sentence or table cell (design §9.2)."""

    kind: Literal[
        "plain",
        "emphasis",
        "strong",
        "strikethrough",
        "code",
        "link",
        "image",
        "hard_break",
    ]
    text: str
    href: str | None = None


class ArticleSentence(ContractModel):
    sentence_id: str
    order: int
    text: str
    translation_zh: str
    audio_start_sample: int
    audio_end_sample: int
    audio_start_ms: int
    audio_end_ms: int
    # v1.1: non-empty run projection for rich rendering. Absent in v1.0.
    runs: list[ArticleRun] = []


class ArticleTableCell(ContractModel):
    cell_id: str
    text: str
    runs: list[ArticleRun] = []


class ArticleBlock(ContractModel):
    """The v1.1 block discriminated union (design §9.2).

    'kind' decides which fields are legal; the semantic validator rejects a
    block whose kind and payload disagree (invalid_markdown_block).
    """

    block_id: str
    kind: Literal[
        "paragraph", "list_item", "quote", "heading", "table", "code", "divider"
    ]
    order: int
    sentences: list[ArticleSentence] = []
    # heading
    level: int | None = None
    # list_item
    list_kind: Literal["bullet", "ordered"] | None = None
    list_depth: int = 0
    list_ordinal: int | None = None
    # quote
    quote_depth: int = 0
    # table
    alignments: list[Literal["default", "left", "center", "right"]] = []
    header: list[ArticleTableCell] = []
    rows: list[list[ArticleTableCell]] = []
    translation_zh: dict[str, str] | None = None
    # code
    language: str | None = None
    code: str | None = None


class ArticlePayload(ContractModel):
    format: Literal["readpack-article"] = "readpack-article"
    format_version: Literal["1.0", "1.1"] = "1.0"
    required_capabilities: list[str] = []
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
