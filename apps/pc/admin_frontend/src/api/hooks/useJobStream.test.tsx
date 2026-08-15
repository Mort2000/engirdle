import { act, renderHook } from "@testing-library/react"
import { QueryClientProvider } from "@tanstack/react-query"
import { beforeEach, describe, expect, it, vi } from "vitest"

import { jobsKeys } from "@/api/hooks/jobs"
import { useJobStream } from "@/api/hooks/useJobStream"
import {
  createTestQueryClient,
  FakeEventSource,
  mockApiFetch,
  stubEventSource,
} from "@/test/testUtils"
import { makeJobDetail, makeProgress } from "@/test/jobFixtures"

function renderStream(jobId: string, enabled = true) {
  const queryClient = createTestQueryClient()
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
  )
  const result = renderHook(() => useJobStream(jobId, { enabled }), { wrapper })
  return { ...result, queryClient }
}

describe("useJobStream", () => {
  beforeEach(() => {
    vi.unstubAllGlobals()
    FakeEventSource.reset()
  })

  it("订阅 /api/jobs/{id}/events，snapshot 直写详情缓存并失效任务查询", () => {
    stubEventSource()
    const { result, queryClient } = renderStream("job-0001")
    const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")

    expect(result.current).toBe("connecting")
    expect(FakeEventSource.last().url).toBe("/api/jobs/job-0001/events")

    const snapshotJob = makeJobDetail({ status: "running" })
    act(() => {
      FakeEventSource.last().emit("snapshot", {
        job: snapshotJob,
        progress: snapshotJob.progress,
      })
    })

    // 未收到 open 前保持 connecting，但缓存已写入、任务查询已失效。
    expect(result.current).toBe("connecting")
    expect(queryClient.getQueryData(jobsKeys.detail("job-0001"))).toEqual(
      snapshotJob,
    )
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: jobsKeys.root })
  })

  it("open 后进入 live；progress 事件仅合并进度字段", () => {
    stubEventSource()
    const { result, queryClient } = renderStream("job-0001")
    const source = FakeEventSource.last()

    const snapshotJob = makeJobDetail({ status: "running" })
    act(() => {
      source.emit("snapshot", {
        job: snapshotJob,
        progress: snapshotJob.progress,
      })
      source.fireOpen()
    })
    expect(result.current).toBe("live")

    const progress = makeProgress({
      stage: "speech",
      stage_index: 2,
      percent: 63.5,
      done_units: 127,
      total_units: 200,
      indeterminate: false,
    })
    act(() => {
      source.emit("progress", progress)
    })

    const cached = queryClient.getQueryData(jobsKeys.detail("job-0001"))
    expect(cached).toMatchObject({ status: "running", progress })
  })

  it("断连降级为 5s 轮询 GET /api/jobs/{id}，重连后停轮询回 SSE", async () => {
    vi.useFakeTimers()
    try {
      stubEventSource()
      const polled = makeJobDetail({ status: "running" })
      const fetchMock = mockApiFetch({
        "/api/jobs/job-0001": () => polled,
      })
      const { result } = renderStream("job-0001")
      const source = FakeEventSource.last()

      act(() => {
        source.fireError()
      })
      expect(result.current).toBe("degraded")

      // 降级立即拉一次，随后每 5s 轮询。
      await act(async () => {
        await vi.advanceTimersByTimeAsync(0)
      })
      expect(fetchMock).toHaveBeenCalledTimes(1)
      expect(fetchMock.mock.calls[0]?.[0]).toBe("/api/jobs/job-0001")

      await act(async () => {
        await vi.advanceTimersByTimeAsync(5000)
      })
      expect(fetchMock).toHaveBeenCalledTimes(2)

      // SSE 重连成功：停止轮询。
      act(() => {
        source.fireOpen()
      })
      expect(result.current).toBe("live")

      await act(async () => {
        await vi.advanceTimersByTimeAsync(10_000)
      })
      expect(fetchMock).toHaveBeenCalledTimes(2)
    } finally {
      vi.useRealTimers()
    }
  })

  it("终态（succeeded）事件关闭连接并进入 closed", () => {
    stubEventSource()
    const { result } = renderStream("job-0001")

    const succeeded = makeJobDetail({
      status: "succeeded",
      progress: makeProgress({
        stage: "complete",
        stage_index: 7,
        percent: 100,
        indeterminate: false,
      }),
    })
    act(() => {
      FakeEventSource.last().emit("status", {
        job: succeeded,
        progress: succeeded.progress,
      })
    })

    expect(result.current).toBe("closed")
    expect(FakeEventSource.last().closed).toBe(true)
  })

  it("降级轮询发现终态后停止轮询并关闭流", async () => {
    vi.useFakeTimers()
    try {
      stubEventSource()
      const succeeded = makeJobDetail({ status: "succeeded" })
      const fetchMock = mockApiFetch({
        "/api/jobs/job-0001": () => succeeded,
      })
      const { result } = renderStream("job-0001")

      act(() => {
        FakeEventSource.last().fireError()
      })
      await act(async () => {
        await vi.advanceTimersByTimeAsync(0)
      })

      expect(result.current).toBe("closed")
      expect(FakeEventSource.last().closed).toBe(true)

      await act(async () => {
        await vi.advanceTimersByTimeAsync(10_000)
      })
      expect(fetchMock).toHaveBeenCalledTimes(1)
    } finally {
      vi.useRealTimers()
    }
  })

  it("卸载关闭连接；enabled=false 不创建 EventSource 并处于 idle", () => {
    stubEventSource()
    const { unmount } = renderStream("job-0001")
    expect(FakeEventSource.instances).toHaveLength(1)

    unmount()
    expect(FakeEventSource.last().closed).toBe(true)

    const before = FakeEventSource.instances.length
    const disabled = renderStream("job-0001", false)
    expect(FakeEventSource.instances).toHaveLength(before)
    expect(disabled.result.current).toBe("idle")
    disabled.unmount()
  })
})
