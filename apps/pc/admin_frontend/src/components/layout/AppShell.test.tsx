import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import {
  createMemoryRouter,
  RouterProvider,
} from "react-router"

import { AppShell } from "@/components/layout/AppShell"
import { ThemeProvider } from "@/lib/theme"

function renderAt(initialPath: string) {
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
  return render(
    <ThemeProvider>
      <RouterProvider router={router} />
    </ThemeProvider>,
  )
}

describe("AppShell", () => {
  it("渲染全部主导航项与验证桩模式徽标占位", () => {
    renderAt("/")

    const nav = screen.getByRole("navigation", { name: "主导航" })
    for (const label of ["工作台", "文章", "任务", "声音配置"]) {
      expect(nav).toHaveTextContent(label)
    }
    expect(screen.getByText("验证桩模式")).toBeInTheDocument()
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
})
