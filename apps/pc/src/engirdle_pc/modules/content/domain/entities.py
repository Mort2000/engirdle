from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class RevisionStatus(str, Enum):
    DRAFT = "draft"
    STRUCTURED = "structured"
    APPROVED = "approved"
    PUBLISHED = "published"


class BlockKind(str, Enum):
    PARAGRAPH = "paragraph"
    LIST_ITEM = "list_item"
    QUOTE = "quote"


@dataclass(frozen=True)
class Sentence:
    sentence_id: str
    order: int
    text: str


@dataclass(frozen=True)
class Block:
    block_id: str
    kind: BlockKind
    order: int
    sentences: tuple[Sentence, ...]


@dataclass(frozen=True)
class SourceAttribution:
    author: str | None
    display_name: str | None
    url: str | None
    license_name: str


@dataclass(frozen=True)
class ArticleRevision:
    article_id: str
    revision: int
    title: str
    raw_text: str
    normalized_text: str
    source: SourceAttribution
    source_sha256: str
    normalized_sha256: str
    structure_sha256: str
    status: RevisionStatus
    blocks: tuple[Block, ...]


@dataclass(frozen=True)
class NewArticle:
    title: str
    body: str
    author: str | None
    source_name: str | None
    source_url: str | None
    license_name: str


@dataclass(frozen=True)
class EditedSentence:
    text: str
    sentence_id: str | None = None


@dataclass(frozen=True)
class EditedBlock:
    kind: BlockKind
    sentences: tuple[EditedSentence, ...]
    block_id: str | None = None
