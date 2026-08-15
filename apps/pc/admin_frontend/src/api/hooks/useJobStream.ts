/**
 * 任务详情实时流 hook（设计 §8.2–§8.4）。
 *
 * EventSource 订阅 `GET /api/jobs/{id}/events`：snapshot/status 事件
 * 直写任务详情缓存并失效任务列表（下次聚焦自然刷新，§8.4.5），progress
 * 事件仅合并进度字段。断连（error）自动降级为 5s 轮询
 * `GET /api/jobs/{id}`（响应与 SSE 负载同构）；EventSource 自动重连
 * 成功（open）后停止轮询回到 SSE。收到终态（succeeded/failed）时
 * 主动关闭连接，避免 EventSource 对已关闭流的无谓重连。
 *
 * 页面在任务进入终态时置 enabled=false（重试后 invalidate 重新拉取，
 * 状态回到 queued 使 enabled 复位，流随之重建）。
 */

import { useEffect, useState } from "react"
import { useQueryClient } from "@tanstack/react-query"

import {
  getJob,
  isTerminalStatus,
  type JobDetailPayload,
  type JobEventPayload,
  type JobProgress,
} from "@/api/jobs"
import { jobsKeys } from "@/api/hooks/jobs"

export type JobStreamState = "connecting" | "live" | "degraded" | "closed" | "idle"

/** SSE 断连期间的降级轮询间隔（设计 §8.4）。 */
export const STREAM_FALLBACK_POLL_MS = 5000

export interface UseJobStreamOptions {
  /** 默认 true；任务终态后页面关闭流（idle），重试成功后复位。 */
  enabled?: boolean
}

interface UseJobStreamContext {
  jobId: string
  queryClient: ReturnType<typeof useQueryClient>
}

function applyJobPayload(
  context: UseJobStreamContext,
  job: JobDetailPayload,
): boolean {
  const key = jobsKeys.detail(context.jobId)
  const previous = context.queryClient.getQueryData<JobDetailPayload>(key)
  context.queryClient.setQueryData(key, job)
  if (previous?.status !== job.status) {
    // 状态迁移才失效列表/详情查询，progress 高频更新不触发。
    void context.queryClient.invalidateQueries({ queryKey: jobsKeys.root })
  }
  return isTerminalStatus(job.status)
}

export function useJobStream(
  jobId: string | undefined,
  options: UseJobStreamOptions = {},
): JobStreamState {
  const enabled = options.enabled ?? true
  const queryClient = useQueryClient()
  const [state, setState] = useState<JobStreamState>(
    enabled && jobId ? "connecting" : "idle",
  )

  useEffect(() => {
    if (!jobId || !enabled) {
      setState("idle")
      return
    }

    let streamEnded = false
    let pollTimer: ReturnType<typeof setInterval> | undefined
    const context: UseJobStreamContext = { jobId, queryClient }

    setState("connecting")

    const stopPolling = () => {
      if (pollTimer !== undefined) {
        clearInterval(pollTimer)
        pollTimer = undefined
      }
    }

    const endStream = () => {
      streamEnded = true
      stopPolling()
      setState("closed")
      source.close()
    }

    const startPolling = () => {
      if (pollTimer !== undefined) {
        return
      }
      const poll = async () => {
        try {
          const job = await getJob(jobId)
          if (pollTimer === undefined) {
            // 轮询已被停止（SSE 恢复或组件卸载），丢弃迟到响应。
            return
          }
          if (applyJobPayload(context, job)) {
            endStream()
          }
        } catch {
          // 轮询失败保持降级态，等下一轮或 SSE 恢复。
        }
      }
      void poll()
      pollTimer = setInterval(poll, STREAM_FALLBACK_POLL_MS)
    }

    const source = new EventSource(`/api/jobs/${jobId}/events`)

    const parse = <T,>(event: Event): T =>
      JSON.parse((event as MessageEvent<string>).data) as T

    source.addEventListener("open", () => {
      // 重连成功：回到 SSE，停掉降级轮询（§8.4 恢复语义）。
      stopPolling()
      if (!streamEnded) {
        setState("live")
      }
    })

    const handleFullState = (event: Event) => {
      const payload = parse<JobEventPayload>(event)
      if (applyJobPayload(context, payload.job)) {
        endStream()
      }
    }
    source.addEventListener("snapshot", handleFullState)
    source.addEventListener("status", handleFullState)

    source.addEventListener("progress", (event: Event) => {
      const progress = parse<JobProgress>(event)
      queryClient.setQueryData<JobDetailPayload>(
        jobsKeys.detail(jobId),
        (previous) => (previous ? { ...previous, progress } : previous),
      )
    })

    source.addEventListener("error", () => {
      if (streamEnded) {
        return
      }
      // EventSource 会自行重连；期间降级为 5s 轮询兜底展示。
      setState("degraded")
      startPolling()
    })

    return () => {
      streamEnded = true
      stopPolling()
      source.close()
    }
  }, [jobId, enabled, queryClient])

  return state
}
