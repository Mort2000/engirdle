import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { KeyValues } from "@/components/KeyValues"

describe("KeyValues", () => {
  it("渲染两列 label/value 网格（dl/dt/dd 语义）", () => {
    render(
      <KeyValues
        items={[
          { label: "任务 ID", value: "job-0001", mono: true },
          { label: "尝试次数", value: 2 },
        ]}
      />,
    )

    const list = screen.getByText("任务 ID").closest("dl")
    expect(list).not.toBeNull()
    expect(screen.getByText("任务 ID")).toBeInTheDocument()
    expect(screen.getByText("job-0001")).toBeInTheDocument()
    expect(screen.getByText("尝试次数")).toBeInTheDocument()
    expect(screen.getByText("2")).toBeInTheDocument()
  })

  it("空数组渲染空网格", () => {
    const { container } = render(<KeyValues items={[]} />)
    expect(container.querySelector("dl")).toBeInTheDocument()
    expect(container.querySelectorAll("dt")).toHaveLength(0)
  })
})
