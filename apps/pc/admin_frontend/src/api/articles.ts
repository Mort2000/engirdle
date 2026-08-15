/**
 * 文章域 API 载荷类型与请求函数（与 api/jobs.ts 同一约定）。
 *
 * 后端端点返回 `dict[str, object]`，这里按 app.py `_revision_payload` /
 * `_block_view` 的实际组装形状声明窄化接口；契约由后端测试与
 * `npm run gen:api` 共同约束（设计 §11）。
 */

import { apiFetch } from "@/api/client"
import type { JobCorePayload } from "@/api/jobs"
import type { EditStructurePayload } from "@/features/articles/editedBlockSchema"

export type RevisionStatus = "draft" | "structured" | "approved" | "published"

/** 文本块样式（TextBlock.kind 与 style 同值：paragraph/heading/list_item/quote）。 */
export type TextBlockKind = "paragraph" | "heading" | "list_item" | "quote"

export type ListKind = "bullet" | "ordered"

export type TableAlignment = "default" | "left" | "center" | "right"

export interface RunView {
  kind: string
  text: string
  href: string | null
}

export interface SentenceView {
  sentence_id: string
  order: number
  text: string
  runs: RunView[]
}

export interface TextBlockView {
  block_id: string
  kind: TextBlockKind
  order: number
  style: TextBlockKind
  level?: number
  list_kind?: ListKind
  list_depth?: number
  list_ordinal?: number | null
  quote_depth?: number
  sentences: SentenceView[]
}

export interface TableCellView {
  cell_id: string
  text: string
  runs: RunView[]
}

export interface TableBlockView {
  block_id: string
  kind: "table"
  order: number
  alignments: TableAlignment[]
  header: TableCellView[]
  rows: TableCellView[][]
}

export interface CodeBlockView {
  block_id: string
  kind: "code"
  order: number
  language: string | null
  code: string
}

export interface DividerBlockView {
  block_id: string
  kind: "divider"
  order: number
}

export type BlockView =
  | TextBlockView
  | TableBlockView
  | CodeBlockView
  | DividerBlockView

export interface RevisionSourceView {
  author: string | null
  display_name: string | null
  url: string | null
  license_name: string
}

export interface RevisionPayload {
  article_id: string
  revision: number
  title: string
  status: RevisionStatus
  source_sha256: string
  normalized_sha256: string
  structure_sha256: string
  /** 原始 Markdown（修订录入页预填编辑器）。 */
  raw_text: string
  source: RevisionSourceView
  blocks: BlockView[]
}

export interface CreateArticleInput {
  title: string
  body: string
  author?: string | null
  source_name?: string | null
  source_url?: string | null
  license_name?: string
}

export interface DeleteArticleResult {
  article_id: string
  trash_path: string
}

export function createArticle(
  input: CreateArticleInput,
): Promise<RevisionPayload> {
  return apiFetch<RevisionPayload>("/api/articles", {
    method: "POST",
    body: JSON.stringify(input),
  })
}

export function createArticleRevision(
  articleId: string,
  input: CreateArticleInput,
): Promise<RevisionPayload> {
  return apiFetch<RevisionPayload>(`/api/articles/${articleId}/revisions`, {
    method: "POST",
    body: JSON.stringify(input),
  })
}

export function getArticle(
  articleId: string,
  revision: number,
): Promise<RevisionPayload> {
  return apiFetch<RevisionPayload>(
    `/api/articles/${articleId}/revisions/${revision}`,
  )
}

/** 各文章最新修订（完整 revision 载荷，修订录入页据此预填表单）。 */
export function listArticles(): Promise<RevisionPayload[]> {
  return apiFetch<RevisionPayload[]>("/api/articles")
}

/** 保存结构化编辑（既有 PUT .../structure 端点，设计 §8.5「不变」）。 */
export function editStructure(
  articleId: string,
  revision: number,
  payload: EditStructurePayload,
): Promise<RevisionPayload> {
  return apiFetch<RevisionPayload>(
    `/api/articles/${articleId}/revisions/${revision}/structure`,
    { method: "PUT", body: JSON.stringify(payload) },
  )
}

/** 冻结结构并创建生产任务（响应为任务载荷）。 */
export function approveArticleRevision(
  articleId: string,
  revision: number,
): Promise<JobCorePayload> {
  return apiFetch<JobCorePayload>(
    `/api/articles/${articleId}/revisions/${revision}/approve`,
    { method: "POST" },
  )
}

/** 已冻结修订重建制品（新任务）。 */
export function rebuildArticleRevision(
  articleId: string,
  revision: number,
): Promise<JobCorePayload> {
  return apiFetch<JobCorePayload>(
    `/api/articles/${articleId}/revisions/${revision}/rebuild`,
    { method: "POST" },
  )
}

export function deleteArticle(
  articleId: string,
  confirmation: string,
): Promise<DeleteArticleResult> {
  return apiFetch<DeleteArticleResult>(
    `/api/articles/${articleId}?confirmation=${encodeURIComponent(confirmation)}`,
    { method: "DELETE" },
  )
}
