import { fireEvent, screen, waitFor } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { JobDetailPage } from "@/features/jobs/JobDetailPage"
import {
  createTestQueryClient,
  FakeEventSource,
  mockApiFetch,
  renderWithProviders,
  stubEventSource,
} from "@/test/testUtils"
import {
  makeAudioReview,
  makeJobDetail,
  makeStructureReport,
  makeTranslationUnits,
} from "@/test/jobFixtures"

function renderDetailPage(jobId = "job-0001") {
  return renderWithProviders(<JobDetailPage />, {
    queryClient: createTestQueryClient(),
    route: `/jobs/${jobId}`,
    path: "/jobs/:jobId",
  })
}

function setupReviewReadyApi() {
  return mockApiFetch({
    "/api/jobs/job-0001": () => makeJobDetail(),
    "/api/jobs/job-0001/translations": () => makeTranslationUnits(),
    "/api/jobs/job-0001/audio": () => makeAudioReview(),
    "/api/articles/art-0001/revisions/2/structure-report": () =>
      makeStructureReport(),
    "/api/jobs/job-0001/translations/sent-0001": () => ({
      sentence_id: "sent-0001",
      text_zh: "你好，世界！（修正）",
    }),
    "/api/jobs/job-0001/table-translations/blk-table-0001": () => ({
      block_id: "blk-table-0001",
      cells: [],
    }),
  })
}

function findPutCall(fetchMock: ReturnType<typeof mockApiFetch>, suffix: string) {
  return fetchMock.mock.calls.find((call) => String(call[0]).endsWith(suffix))
}

describe("JobDetailPage", () => {
  beforeEach(() => {
    stubEventSource()
    FakeEventSource.reset()
  })
  afterEach(() => {
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it("渲染页头、Stepper 当前阶段、进度与详情分组", async () => {
    setupReviewReadyApi()

    renderDetailPage()

    expect(
      await screen.findByRole("heading", { level: 1, name: "任务 job-0001" }),
    ).toBeInTheDocument()
    expect(screen.getByText("待人工审阅")).toBeInTheDocument()
    expect(screen.getByText("尝试 1 次")).toBeInTheDocument()

    // 进度面板：Stepper 当前阶段 = 人工审阅（stage_index 4），总进度 97.0%。
    const reviewNode = document.querySelector<HTMLElement>('[data-stage="review"]')
    expect(reviewNode?.dataset["state"]).toBe("current")
    expect(screen.getByText("97.0%")).toBeInTheDocument()

    // 详情分组：适配器 / 配置快照 / 处理计数（structure-report）。
    expect(screen.getAllByText("适配器").length).toBeGreaterThanOrEqual(1)
    expect(screen.getByText("stub-tts")).toBeInTheDocument()
    expect(screen.getByText("音频编码")).toBeInTheDocument()
    await waitFor(() => {
      expect(screen.getByText("翻译句数").parentElement).toHaveTextContent("12")
    })

    // 审阅状态提供发布入口。
    expect(screen.getByRole("button", { name: /构建并发布/ })).toBeInTheDocument()
  })

  it("译文审阅：句级三列展示并可保存修正（PUT）", async () => {
    const fetchMock = setupReviewReadyApi()

    renderDetailPage()

    // 三列内容：原文 / 机翻（textarea 初始值同文，允许重复匹配）。
    expect(await screen.findByText("Hello world.")).toBeInTheDocument()
    expect(screen.getAllByText("你好，世界。").length).toBeGreaterThanOrEqual(1)
    // 原文列与音频审阅句列表共用 source_text，允许重复匹配。
    expect(screen.getAllByText("Second sentence.").length).toBeGreaterThanOrEqual(1)
    expect(
      screen.getByLabelText("修正译文 sent-0002").textContent,
    ).toBe("第二句。")

    fireEvent.change(screen.getByLabelText("修正译文 sent-0001"), {
      target: { value: "你好，世界！（修正）" },
    })
    fireEvent.click(screen.getAllByRole("button", { name: "保存修正" })[0]!)

    await waitFor(() => {
      const editCall = findPutCall(fetchMock, "/translations/sent-0001")
      expect(editCall).toBeDefined()
      expect(editCall?.[1]?.method).toBe("PUT")
      expect(editCall?.[1]?.body).toBe(
        JSON.stringify({ text_zh: "你好，世界！（修正）" }),
      )
    })
  })

  it("表格译文审阅：cell 级编辑并整表保存（PUT）", async () => {
    const fetchMock = setupReviewReadyApi()

    renderDetailPage()

    const cell = await screen.findByLabelText("表格单元格 cell-0001")
    fireEvent.change(cell, { target: { value: "列 A 修正" } })
    fireEvent.click(screen.getByRole("button", { name: "保存整表修正" }))

    await waitFor(() => {
      const editCall = findPutCall(fetchMock, "/table-translations/blk-table-0001")
      expect(editCall).toBeDefined()
      expect(editCall?.[1]?.method).toBe("PUT")
      expect(JSON.parse(String(editCall?.[1]?.body))).toEqual({
        cells: [
          { cell_id: "cell-0001", text_zh: "列 A 修正" },
          { cell_id: "cell-0002", text_zh: "列 B" },
        ],
      })
    })
  })

  it("音频审阅：播放器、完整性计数与句级播放", async () => {
    setupReviewReadyApi()
    const playMock = vi
      .spyOn(HTMLMediaElement.prototype, "play")
      .mockResolvedValue(undefined)

    renderDetailPage()

    expect(await screen.findByTestId("review-audio")).toBeInTheDocument()
    expect(screen.getByText("缺失 0")).toBeInTheDocument()
    expect(screen.getByText("零时长 1")).toBeInTheDocument()
    expect(screen.getByText("异常时长 0")).toBeInTheDocument()

    fireEvent.click(screen.getAllByRole("button", { name: "播放此句" })[0]!)
    await waitFor(() => {
      expect(playMock).toHaveBeenCalled()
    })
  })

  it("SSE snapshot 事件驱动页面更新并终态关闭流", async () => {
    // GET 夹具跟随 SSE 更新（快照会失效详情查询触发重取）。
    let latest = makeJobDetail()
    mockApiFetch({
      "/api/jobs/job-0001": () => latest,
      "/api/jobs/job-0001/translations": () => makeTranslationUnits(),
      "/api/jobs/job-0001/audio": () => makeAudioReview(),
      "/api/articles/art-0001/revisions/2/structure-report": () =>
        makeStructureReport(),
    })

    renderDetailPage()
    await screen.findByRole("heading", { level: 1, name: "任务 job-0001" })

    latest = makeJobDetail({
      status: "succeeded",
      progress: {
        stage: "complete",
        stage_index: 7,
        percent: 100,
        done_units: null,
        total_units: null,
        indeterminate: false,
      },
    })
    FakeEventSource.last().emit("snapshot", {
      job: latest,
      progress: latest.progress,
    })

    await waitFor(() => {
      expect(screen.getByText("已成功")).toBeInTheDocument()
    })
    expect(FakeEventSource.last().closed).toBe(true)
    expect(screen.getByText("发布完成")).toBeInTheDocument()
  })

  it("失败任务：失败面板展示错误码并提供重试", async () => {
    mockApiFetch({
      "/api/jobs/job-0002": () =>
        makeJobDetail({
          job_id: "job-0002",
          article_id: "art-0002",
          status: "failed",
          stage: "translation",
          error: { code: "translation_failed", message: "adapter blew up" },
          progress: {
            stage: "translation",
            stage_index: 1,
            percent: 15,
            done_units: 1,
            total_units: 3,
            indeterminate: false,
          },
        }),
      "/api/jobs/job-0002/translations": () => [],
      "/api/articles/art-0002/revisions/2/structure-report": () =>
        makeStructureReport({ article_id: "art-0002" }),
    })

    renderDetailPage("job-0002")

    expect(await screen.findByText("任务失败")).toBeInTheDocument()
    expect(screen.getByText("translation_failed")).toBeInTheDocument()
    expect(screen.getByText("adapter blew up")).toBeInTheDocument()
    expect(screen.getAllByRole("button", { name: /重试/ }).length).toBe(2)

    // 失败状态无发布按钮。
    expect(screen.queryByRole("button", { name: /构建并发布/ })).toBeNull()
  })

  it("任务不存在：错误态与返回链接", async () => {
    mockApiFetch({})

    renderDetailPage("job-missing")

    await waitFor(() => {
      expect(screen.getByRole("alert")).toHaveTextContent("任务加载失败")
    })
    expect(
      screen.getByRole("link", { name: "返回任务列表" }),
    ).toBeInTheDocument()
  })
})
