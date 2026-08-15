/**
 * DashboardPage 集成测试（设计 §8.5 / 本阶段 spec）：
 * - summary 单次往返渲染：概览卡片、文章库、近期任务（徽标 + 链接）、
 *   发布制品、发布器面板（绑定地址/风险提示/进程状态）；
 * - 发布器启停交互（既有 /api/publisher/* 端点）；
 * - 删除文章 AlertDialog 输入门控（输入文章 ID 确认）；
 * - 验证模式提示、加载骨架与错误态。
 */

import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

import { DashboardPage } from "@/features/dashboard/DashboardPage"
import { mockApiFetch, renderWithProviders } from "@/test/testUtils"
import { makeJobDetail, makeProgress } from "@/test/jobFixtures"
import type { DashboardSummaryPayload } from "@/api/dashboard"

function makeSummary(
  overrides: Partial<DashboardSummaryPayload> = {},
): DashboardSummaryPayload {
  return {
    articles: [
      {
        article_id: "art-0001",
        revision: 2,
        title: "First article",
        status: "structured",
        source: { author: "Ada", display_name: null, url: null, license_name: "unknown" },
      },
      {
        article_id: "art-0002",
        revision: 1,
        title: "Second article",
        status: "published",
        source: { author: null, display_name: null, url: null, license_name: "unknown" },
      },
    ],
    jobs: [
      makeJobDetail({
        job_id: "job-alpha",
        article_id: "art-0001",
        status: "running",
        progress: makeProgress({ stage: "speech", percent: 42 }),
      }),
      makeJobDetail({
        job_id: "job-beta",
        article_id: "art-0002",
        status: "failed",
        progress: makeProgress({ stage: "translation", percent: 10 }),
      }),
    ],
    published: [
      {
        package_id: "pkg-0001",
        article_id: "art-0002",
        revision: 1,
        artifact_revision: 1,
        title: "Second article",
        opaque_name: "opaque-1",
        size: 2_048,
        sha256: "d".repeat(64),
        published_at: "2026-08-15T08:00:00+00:00",
      },
    ],
    artifacts: [
      {
        package_id: "pkg-0002",
        article_id: "art-0002",
        revision: 1,
        artifact_revision: 2,
        size: 4_096,
        sha256: "e".repeat(64),
        state: "validated",
        created_at: "2026-08-15T09:00:00+00:00",
      },
    ],
    publisher: {
      running: true,
      binding_host: "0.0.0.0",
      port: 8080,
      binding_url: "http://0.0.0.0:8080",
      started_at: "2026-08-15T07:00:00+00:00",
      pid: 4242,
      last_exit_code: 0,
      authentication: "none",
      trusted_network_only: true,
    },
    catalog_available: true,
    verification_mode: false,
    ...overrides,
  }
}

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

describe("DashboardPage", () => {
  it("单次往返渲染概览卡片与各面板数据", async () => {
    const fetchMock = mockApiFetch({
      "/api/dashboard/summary": () => makeSummary(),
    })

    renderWithProviders(<DashboardPage />, { route: "/", path: "/" })

    // 概览卡片。
    expect(await screen.findByText("文章")).toBeInTheDocument()
    expect(screen.getByText("生产任务")).toBeInTheDocument()
    expect(screen.getByText("当前发布")).toBeInTheDocument()
    expect(screen.getByText("可重新发布制品")).toBeInTheDocument()

    // 文章库：标题链接 + 状态徽标 + 删除入口。
    const articleLink = screen.getByRole("link", { name: "First article" })
    expect(articleLink).toHaveAttribute(
      "href",
      "/articles/art-0001/revisions/2",
    )
    expect(screen.getByText("已解析")).toBeInTheDocument()
    expect(screen.getByText("已发布")).toBeInTheDocument()

    // 近期任务：状态徽标 + 链接 /jobs/:id。
    const jobLink = screen.getByRole("link", { name: /语音合成/ })
    expect(jobLink).toHaveAttribute("href", "/jobs/job-alpha")
    expect(screen.getByText("失败")).toBeInTheDocument()

    // 发布制品。
    expect(screen.getByText(/2\.0 KB/)).toBeInTheDocument()
    expect(screen.getByText(/4\.0 KB/)).toBeInTheDocument()
    expect(screen.getByText(/validated/)).toBeInTheDocument()

    // 发布器面板：绑定地址、风险提示与进程状态（任务徽标与发布器状态
    // 均含“运行中”）。
    expect(screen.getByText("http://0.0.0.0:8080")).toBeInTheDocument()
    expect(screen.getByText("风险提示")).toBeInTheDocument()
    expect(screen.getByText("4242")).toBeInTheDocument()
    expect(screen.getAllByText("运行中")).toHaveLength(2)

    // 单次往返：summary 只请求一次（无其他面板级请求）。
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it("验证模式渲染琥珀提示", async () => {
    mockApiFetch({
      "/api/dashboard/summary": () => makeSummary({ verification_mode: true }),
    })

    renderWithProviders(<DashboardPage />, { route: "/", path: "/" })

    // 页面上同时存在验证模式与风险提示两个 alert（§6.3）。
    const alerts = await screen.findAllByRole("alert")
    const verification = alerts.find((alert) =>
      alert.textContent?.includes("验证模式"),
    )
    expect(verification).toBeDefined()
    expect(verification).toHaveTextContent("翻译与 TTS 当前为验证桩")
  })

  it("发布器启停走既有 publisher 端点", async () => {
    const fetchMock = mockApiFetch({
      "/api/dashboard/summary": () =>
        makeSummary({
          publisher: {
            running: false,
            binding_host: "0.0.0.0",
            port: 8080,
            binding_url: "http://0.0.0.0:8080",
            started_at: null,
            pid: null,
            last_exit_code: 1,
            authentication: "none",
            trusted_network_only: true,
          },
        }),
      "/api/publisher/start": () => makeSummary().publisher,
    })

    renderWithProviders(<DashboardPage />, { route: "/", path: "/" })

    const startButton = await screen.findByRole("button", {
      name: "启动局域网服务",
    })
    expect(screen.getByText("已停止")).toBeInTheDocument()

    fireEvent.click(startButton)

    await waitFor(() => {
      const start = fetchMock.mock.calls.find(
        (call) => call[0] === "/api/publisher/start",
      )
      expect(start).toBeDefined()
      expect(start![1]?.method).toBe("POST")
    })
  })

  it("删除文章 AlertDialog：输入文章 ID 门控后走 DELETE 端点", async () => {
    const fetchMock = mockApiFetch({
      "/api/dashboard/summary": () => makeSummary(),
      "/api/articles/art-0001": () => ({
        article_id: "art-0001",
        trash_path: "/tmp/trash/art-0001",
      }),
    })

    renderWithProviders(<DashboardPage />, { route: "/", path: "/" })

    fireEvent.click(
      await screen.findByRole("button", { name: "删除文章 art-0001" }),
    )
    const confirmInput = await screen.findByLabelText("输入文章 ID 以确认")

    // 输入不匹配：确认按钮禁用。
    fireEvent.change(confirmInput, { target: { value: "wrong-id" } })
    expect(screen.getByRole("button", { name: "确认删除" })).toBeDisabled()

    // 输入匹配：DELETE 携带 confirmation 查询参数。
    fireEvent.change(confirmInput, { target: { value: "art-0001" } })
    expect(screen.getByRole("button", { name: "确认删除" })).toBeEnabled()
    fireEvent.click(screen.getByRole("button", { name: "确认删除" }))

    await waitFor(() => {
      const remove = fetchMock.mock.calls.find(
        (call) =>
          typeof call[0] === "string" &&
          call[0].startsWith("/api/articles/art-0001?confirmation="),
      )
      expect(remove).toBeDefined()
      expect(remove![1]?.method).toBe("DELETE")
      expect(remove![0]).toContain("confirmation=art-0001")
    })
  })

  it("加载中渲染骨架", () => {
    mockApiFetch({
      "/api/dashboard/summary": () => new Promise<never>(() => {}),
    })

    renderWithProviders(<DashboardPage />, { route: "/", path: "/" })
    expect(screen.getByLabelText("工作台加载中")).toBeInTheDocument()
  })

  it("请求失败渲染错误提示", async () => {
    mockApiFetch({})

    renderWithProviders(<DashboardPage />, { route: "/", path: "/" })

    await waitFor(() => {
      expect(screen.getByRole("alert")).toHaveTextContent("工作台加载失败")
    })
  })
})
