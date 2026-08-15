/**
 * 工作台域 API 载荷类型与请求函数（与 api/jobs.ts 同一约定）。
 *
 * 后端端点返回 `dict[str, object]`（OpenAPI 生成类型为 unknown 记录），
 * 这里按 app.py `dashboard_summary` / `_publisher_status_payload` /
 * `_article_summary_payload` / `_published_payload` / `_artifact_payload`
 * 的实际组装形状声明窄化接口；契约由后端测试与 `npm run gen:api`
 * 共同约束（设计 §8.5 / §11）。
 */

import { apiFetch } from "@/api/client"
import type { JobDetailPayload } from "@/api/jobs"

/** 发布器持久化进程状态（含绑定地址与最近退出码）。 */
export interface PublisherStatusPayload {
  running: boolean
  binding_host: string
  port: number
  binding_url: string
  started_at: string | null
  pid: number | null
  last_exit_code: number | null
  authentication: string
  trusted_network_only: boolean
}

/** 文章库摘要（各文章最新修订，不含块详情）。 */
export interface ArticleSummaryPayload {
  article_id: string
  revision: number
  title: string
  status: string
  source: {
    author: string | null
    display_name: string | null
    url: string | null
    license_name: string
  }
}

/** 当前发布制品（publishing.list_current）。 */
export interface PublishedPayload {
  package_id: string
  article_id: string
  revision: number
  artifact_revision: number
  title: string
  opaque_name: string
  size: number
  sha256: string
  published_at: string
}

/** 可重新发布制品（local_library.list_artifacts，state: validated/published）。 */
export interface ArtifactPayload {
  package_id: string
  article_id: string
  revision: number
  artifact_revision: number
  size: number
  sha256: string
  state: string
  created_at: string
}

/**
 * GET /api/dashboard/summary：工作台聚合（设计 §8.5），
 * 单次往返携带全部面板数据。
 */
export interface DashboardSummaryPayload {
  articles: ArticleSummaryPayload[]
  jobs: JobDetailPayload[]
  published: PublishedPayload[]
  artifacts: ArtifactPayload[]
  publisher: PublisherStatusPayload
  catalog_available: boolean
  verification_mode: boolean
}

export function getDashboardSummary(): Promise<DashboardSummaryPayload> {
  return apiFetch<DashboardSummaryPayload>("/api/dashboard/summary")
}

/** 启动局域网只读服务（无鉴权，仅信任网络；失败返回 503 detail）。 */
export function startPublisher(): Promise<PublisherStatusPayload> {
  return apiFetch<PublisherStatusPayload>("/api/publisher/start", {
    method: "POST",
  })
}

export function stopPublisher(): Promise<PublisherStatusPayload> {
  return apiFetch<PublisherStatusPayload>("/api/publisher/stop", {
    method: "POST",
  })
}

/** 重新发布历史制品（既有端点，语义与旧页面按钮一致）。 */
export function republishArtifact(
  packageId: string,
): Promise<{ package_id: string }> {
  return apiFetch<{ package_id: string }>(
    `/api/artifacts/${packageId}/republish`,
    { method: "POST" },
  )
}
