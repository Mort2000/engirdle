/**
 * AppShell 布局测试（设计 §6.1）：
 * - 主导航项渲染与当前路由高亮（含任务详情深链）；
 * - 侧栏折叠保留可访问名称；
 * - 主题切换联动 ThemeProvider；
 * - 验证桩模式徽标按 /api/dashboard/summary 的 verification_mode 门控：
 *   true 显示，false / 查询失败（无数据）不显示，避免真实适配器下误报。
 */

import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  createMemoryRouter,
  RouterProvider,
} from "react-router"
import type { Mock } from "vitest"

import { AppShell } from "@/components/layout/AppShell"
import { ThemeProvider } from "@/lib/theme"
import { createTestQueryClient, mockApiFetch } from "@/test/testUtils"

// AppShell 仅消费 summary 的 verification_mode 字段；完整载荷形状与
// 渲染细节由 DashboardPage 测试覆盖，这里用最小对象驱动徽标门控。
function makeSummary(verificationMode: boolean) {
  return { verification_mode: verificationMode }
}

function renderAt(
  initialPath: string,
  options?: { verificationMode?: boolean; summaryError?: boolean },
): { fetchMock: Mock } {
  const fetchMock = options?.summaryError
    ? // 无路由命中 → 404 → summary 查询失败，data 为 undefined。
      mockApiFetch({})
    : mockApiFetch({
        "/api/dashboard/summary": () =>
          makeSummary(options?.verificationMode ?? false),
      })
  const router = createMemoryRouter(
    [
      {
        element: <AppShell />,
        children: [
          { path: "/", element: <p>工作台占位</p> },
          { path: "/jobs", element: <p>任务占位</p> },
          { path: "/jobs/:jobId", element: <p>任务详情占位</p> },
        ],
      },
    ],
    { initialEntries: [initialPath] },
  )
  render(
    <QueryClientProvider client={createTestQueryClient()}>
      <ThemeProvider>
        <RouterProvider router={router} />
      </ThemeProvider>
    </QueryClientProvider>,
  )
  return { fetchMock }
}

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("AppShell", () => {
  it("渲染全部主导航项", () => {
    renderAt("/")

    const nav = screen.getByRole("navigation", { name: "主导航" })
    for (const label of ["工作台", "文章", "任务", "声音配置"]) {
      expect(nav).toHaveTextContent(label)
    }
  })

  it("当前路由对应的导航项高亮", () => {
    renderAt("/jobs")

    expect(screen.getByRole("link", { name: "任务" })).toHaveAttribute(
      "aria-current",
      "page",
    )
    expect(screen.getByRole("link", { name: "工作台" })).not.toHaveAttribute(
      "aria-current",
    )
  })

  it("任务详情深链仍高亮任务导航项", () => {
    renderAt("/jobs/job-123")

    expect(screen.getByRole("link", { name: "任务" })).toHaveAttribute(
      "aria-current",
      "page",
    )
    expect(screen.getByText("任务详情占位")).toBeInTheDocument()
  })

  it("折叠侧边栏后隐藏导航文字但保留可访问名称", () => {
    renderAt("/")

    fireEvent.click(screen.getByRole("button", { name: "折叠侧边栏" }))

    expect(screen.getByRole("button", { name: "展开侧边栏" })).toBeInTheDocument()
    const jobsLink = screen.getByRole("link", { name: "任务" })
    expect(jobsLink).toHaveAttribute("title", "任务")
    expect(jobsLink.textContent).toBe("")
  })

  it("底部主题切换按钮联动 ThemeProvider", () => {
    window.localStorage.removeItem("engirdle-admin-theme")
    renderAt("/")

    const toggle = screen.getByRole("button", { name: "切换到暗色主题" })
    fireEvent.click(toggle)

    expect(document.documentElement).toHaveClass("dark")
    expect(
      screen.getByRole("button", { name: "切换到亮色主题" }),
    ).toBeInTheDocument()
  })

  it("verification_mode 为 true 时渲染验证桩模式徽标", async () => {
    renderAt("/", { verificationMode: true })

    expect(await screen.findByText("验证桩模式")).toBeInTheDocument()
  })

  it("verification_mode 为 false 时不渲染验证桩模式徽标", async () => {
    const { fetchMock } = renderAt("/", { verificationMode: false })

    await waitFor(() => expect(fetchMock).toHaveBeenCalled())
    expect(screen.queryByText("验证桩模式")).not.toBeInTheDocument()
  })

  it("summary 查询失败（无数据）时不渲染徽标，避免误报", async () => {
    const { fetchMock } = renderAt("/", { summaryError: true })

    await waitFor(() => expect(fetchMock).toHaveBeenCalled())
    expect(screen.queryByText("验证桩模式")).not.toBeInTheDocument()
  })
})
