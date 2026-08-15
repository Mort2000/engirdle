import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { Stepper } from "@/components/progress/Stepper"
import { PIPELINE_STAGES } from "@/lib/progress"

function stageNodes(): HTMLElement[] {
  return Array.from(document.querySelectorAll<HTMLElement>("[data-stage]"))
}

describe("Stepper", () => {
  it("按 §6.3 渲染节点状态：完成实心 / 当前描边 / 未到灰", () => {
    render(<Stepper stages={PIPELINE_STAGES} currentIndex={2} />)

    const nodes = stageNodes()
    expect(nodes).toHaveLength(8)
    expect(nodes.map((node) => node.dataset["state"])).toEqual([
      "done",
      "done",
      "current",
      "pending",
      "pending",
      "pending",
      "pending",
      "pending",
    ])
  })

  it("当前阶段标注中文名并携带 aria-current=step", () => {
    render(<Stepper stages={PIPELINE_STAGES} currentIndex={2} />)

    const current = screen.getByText("语音合成")
    expect(current.closest("li")).toHaveAttribute("aria-current", "step")
  })

  it("八阶段中文名完整渲染（Stepper 标注）", () => {
    render(<Stepper stages={PIPELINE_STAGES} currentIndex={0} />)

    for (const stage of PIPELINE_STAGES) {
      expect(screen.getByText(stage.label)).toBeInTheDocument()
    }
  })

  it("未知阶段全部置灰", () => {
    render(<Stepper stages={PIPELINE_STAGES} currentIndex={-1} />)

    expect(
      stageNodes().every((node) => node.dataset["state"] === "pending"),
    ).toBe(true)
  })
})
