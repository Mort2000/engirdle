import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { PagePlaceholder } from "@/components/layout/PagePlaceholder"

describe("PagePlaceholder", () => {
  it("渲染页标题与描述", () => {
    render(
      <PagePlaceholder title="工作台" description="管理端概览占位页。" />,
    )

    expect(
      screen.getByRole("heading", { level: 1, name: "工作台" }),
    ).toBeInTheDocument()
    expect(screen.getByText("管理端概览占位页。")).toBeInTheDocument()
  })
})
