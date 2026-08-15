import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { Button } from "@/components/ui/button"

describe("Button", () => {
  it("渲染按钮并应用主变体样式", () => {
    render(<Button>保存</Button>)

    const button = screen.getByRole("button", { name: "保存" })
    expect(button).toBeInTheDocument()
    expect(button.className).toContain("bg-primary")
  })

  it("渲染为幽灵变体", () => {
    render(<Button variant="ghost">取消</Button>)

    expect(screen.getByRole("button", { name: "取消" }).className).toContain(
      "hover:bg-accent",
    )
  })
})
