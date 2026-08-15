import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router"
import { describe, expect, it } from "vitest"

import { PagePlaceholder } from "@/components/layout/PagePlaceholder"

describe("PagePlaceholder", () => {
  it("渲染面包屑、页标题与描述", () => {
    render(
      <MemoryRouter>
        <PagePlaceholder
          title="工作台"
          description="管理端概览占位页。"
          breadcrumbs={[{ label: "工作台", to: "/" }, { label: "概览" }]}
        />
      </MemoryRouter>,
    )

    const breadcrumb = screen.getByRole("navigation", { name: "面包屑" })
    expect(breadcrumb).toHaveTextContent("工作台")
    expect(breadcrumb).toHaveTextContent("概览")
    expect(
      screen.getByRole("heading", { level: 1, name: "工作台" }),
    ).toBeInTheDocument()
    expect(screen.getByText("管理端概览占位页。")).toBeInTheDocument()
  })

  it("渲染右上主操作区骨架", () => {
    render(
      <PagePlaceholder
        title="声音配置"
        description="占位页。"
        breadcrumbs={[{ label: "声音配置" }]}
        actions={<button type="button">新建锚点候选</button>}
      />,
    )

    expect(screen.getByRole("button", { name: "新建锚点候选" })).toBeInTheDocument()
  })
})
