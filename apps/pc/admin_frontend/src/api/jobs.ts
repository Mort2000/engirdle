/**
 * 任务域 API 载荷类型与请求函数。
 *
 * 后端端点返回 `dict[str, object]`（OpenAPI 生成类型为 unknown 记录），
 * 这里按 app.py 的实际组装形状声明窄化接口；契约变更由
 * `npm run gen:api` + 后端测试共同约束（设计 §11）。
 */

import { apiFetch } from "@/api/client"
import type { ProgressLike } from "@/lib/progress"

export type JobStatus =
  | "queued"
  | "running"
  | "review_required"
  | "failed"
  | "succeeded"

export type JobProgress = ProgressLike

export interface JobError {
  code: string | null
  message: string | null
}

/** GET /api/jobs 与 /api/jobs/{id} 的公共形状（重试响应缺 progress）。 */
export interface JobCorePayload {
  job_id: string
  article_id: string
  revision: number
  status: JobStatus
  stage: string
  attempts: number
  translation_adapter: string
  speech_adapter: string
  config_snapshot: {
    pipeline_version: string
    segmenter: string
    translation: {
      adapter: string
      provider: string
      endpoint: string
      model: string
      thinking: string
      reasoning_effort: string
      prompt: string
    }
    speech: {
      adapter: string
      custom_voice_model: string
      base_model: string
      generation: string
      voice_profile: string
      anchor_sha256: string
    }
    audio_encoding: {
      codec: string
      bitrate_kbps: number
      loudness_target_lufs: number
      true_peak_dbfs: number
      loudness_range_lu: number
    }
  }
  created_at: string
  started_at: string | null
  heartbeat_at: string | null
  finished_at: string | null
  error: JobError | null
}

/** GET /api/jobs/{id}：JobCorePayload + 派生 progress（REST 与 SSE 同构）。 */
export interface JobDetailPayload extends JobCorePayload {
  progress: JobProgress
}

/** SSE snapshot/status 事件的负载（设计 §8.2）。 */
export interface JobEventPayload {
  job: JobDetailPayload
  progress: JobProgress
}

export function isTerminalStatus(status: JobStatus | undefined): boolean {
  return status === "succeeded" || status === "failed"
}

export function isAudioReadyStatus(status: JobStatus | undefined): boolean {
  return status === "review_required" || status === "succeeded"
}

export interface SentenceTranslationPayload {
  unit_kind: "sentence"
  unit_id: string
  sentence_id: string
  source_text: string
  generated_text: string
  edited_text: string | null
  published_text: string
}

export interface TableTranslationCellPayload {
  cell_id: string
  generated_text: string
  edited_text: string | null
  published_text: string
}

export interface TableTranslationPayload {
  unit_kind: "table"
  unit_id: string
  cells: TableTranslationCellPayload[]
}

export type TranslationUnitPayload =
  | SentenceTranslationPayload
  | TableTranslationPayload

export interface AudioReviewPayload {
  url: string
  duration_ms: number
  sample_rate_hz: number
  channels: number
  encoder_version: string
  sentences: {
    sentence_id: string
    start_ms: number
    end_ms: number
  }[]
  checks: {
    missing_sentence_ids: string[]
    zero_duration_sentence_ids: string[]
    abnormal_duration_sentence_ids: string[]
  }
}

/** 结构树节点（structure-report 端点；translates/narrates 为派生只读）。 */
export interface StructureTreeNode {
  block_id: string
  kind: string
  translates: boolean
  narrates: boolean
  summary?: string
  sentence_count?: number
  detail?: string
}

export interface StructureReportPayload {
  article_id: string
  revision: number
  warnings: { code: string; message: string }[]
  structure_tree: StructureTreeNode[]
  processing_counts: {
    translated_sentences: number
    translated_tables: number
    skipped_code_blocks: number
    narrated_sentences: number
  }
}

export interface PublishResultPayload {
  package_id: string
  article_id: string
  revision: number
  artifact_revision: number
  size: number
  sha256: string
}

export function listJobs(): Promise<JobDetailPayload[]> {
  return apiFetch<JobDetailPayload[]>("/api/jobs")
}

export function getJob(jobId: string): Promise<JobDetailPayload> {
  return apiFetch<JobDetailPayload>(`/api/jobs/${jobId}`)
}

export function retryJob(jobId: string): Promise<JobCorePayload> {
  return apiFetch<JobCorePayload>(`/api/jobs/${jobId}/retry`, {
    method: "POST",
  })
}

export function publishJob(jobId: string): Promise<PublishResultPayload> {
  return apiFetch<PublishResultPayload>(`/api/jobs/${jobId}/publish`, {
    method: "POST",
  })
}

export function listTranslations(
  jobId: string,
): Promise<TranslationUnitPayload[]> {
  return apiFetch<TranslationUnitPayload[]>(
    `/api/jobs/${jobId}/translations`,
  )
}

export function editSentenceTranslation(
  jobId: string,
  sentenceId: string,
  textZh: string,
): Promise<{ sentence_id: string; text_zh: string }> {
  return apiFetch(`/api/jobs/${jobId}/translations/${sentenceId}`, {
    method: "PUT",
    body: JSON.stringify({ text_zh: textZh }),
  })
}

export function editTableTranslation(
  jobId: string,
  blockId: string,
  cells: { cell_id: string; text_zh: string }[],
): Promise<{ block_id: string; cells: { cell_id: string; text_zh: string }[] }> {
  return apiFetch(`/api/jobs/${jobId}/table-translations/${blockId}`, {
    method: "PUT",
    body: JSON.stringify({ cells }),
  })
}

export function getAudioReview(jobId: string): Promise<AudioReviewPayload> {
  return apiFetch<AudioReviewPayload>(`/api/jobs/${jobId}/audio`)
}

export function getStructureReport(
  articleId: string,
  revision: number,
): Promise<StructureReportPayload> {
  return apiFetch<StructureReportPayload>(
    `/api/articles/${articleId}/revisions/${revision}/structure-report`,
  )
}
