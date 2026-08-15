import { act, screen, waitFor } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { JobsListPage } from "@/features/jobs/JobsListPage"
import {
  createTestQueryClient,
  mockApiFetch,
  renderWithProviders,
  stubEventSource,
} from "@/test/testUtils"
import { makeJobDetail, makeProgress } from "@/test/jobFixtures"

function renderListPage() {
  return renderWithProviders(<JobsListPage />, {
    queryClient: createTestQueryClient(),
    route: "/jobs",
    path: "/jobs",
  })
}

describe("JobsListPage", () => {
  beforeEach(() => {
    stubEventSource()
  })
  afterEach(() => {
    vi.unstubAllGlobals()
    vi.useRealTimers()
  })

  it("渲染任务行：ID 链接、状态徽标、阶段与进度", async () => {
    const fetchMock = mockApiFetch({
      "/api/jobs": () => [
        makeJobDetail({
          job_id: "job-alpha",
          status: "running",
          progress: makeProgress({
            stage: "speech",
            stage_index: 2,
            percent: 63.5,
            done_units: 127,
            total_units: 200,
            indeterminate: false,
          }),
        }),
        makeJobDetail({
          job_id: "job-beta",
          status: "failed",
          progress: makeProgress({
            stage: "translation",
            stage_index: 1,
            percent: 15,
            done_units: 1,
            total_units: 3,
            indeterminate: false,
          }),
        }),
      ],
    })

    renderListPage()

    const link = await screen.findByRole("link", { name: "job-alph" })
    expect(link).toHaveAttribute("href", "/jobs/job-alpha")
    expect(screen.getByRole("link", { name: "job-beta" })).toBeInTheDocument()

    expect(screen.getByText("运行中")).toBeInTheDocument()
    expect(screen.getByText("失败")).toBeInTheDocument()
    expect(screen.getByText("语音合成")).toBeInTheDocument()
    expect(screen.getByText("翻译")).toBeInTheDocument()
    expect(screen.getByText("63.5%")).toBeInTheDocument()
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it("空任务列表渲染空态提示", async () => {
    mockApiFetch({ "/api/jobs": () => [] })

    renderListPage()

    expect(await screen.findByText("暂无任务")).toBeInTheDocument()
    expect(
      screen.getByText("从工作台或文章结构页提交构建后，任务会出现在这里。"),
    ).toBeInTheDocument()
  })

  it("加载中渲染骨架", () => {
    mockApiFetch({
      "/api/jobs": () => new Promise<never>(() => {}),
    })

    renderListPage()

    expect(screen.getByLabelText("任务列表加载中")).toBeInTheDocument()
  })

  it("请求失败渲染错误提示", async () => {
    mockApiFetch({})

    renderListPage()

    await waitFor(() => {
      expect(screen.getByRole("alert")).toHaveTextContent("任务列表加载失败")
    })
  })

  it("5 秒轮询刷新列表（fake timers）", async () => {
    vi.useFakeTimers()
    const fetchMock = mockApiFetch({ "/api/jobs": () => [makeJobDetail()] })

    renderListPage()

    await act(async () => {
      await vi.advanceTimersByTimeAsync(0)
    })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(screen.getByRole("link", { name: "job-0001" })).toBeInTheDocument()

    await act(async () => {
      await vi.advanceTimersByTimeAsync(5000)
    })
    expect(fetchMock).toHaveBeenCalledTimes(2)

    await act(async () => {
      await vi.advanceTimersByTimeAsync(5000)
    })
    expect(fetchMock).toHaveBeenCalledTimes(3)
  })
})
