/**
 * VoiceNewPage 集成测试：speaker 选择（Radix Select）、默认锚点文本、
 * 校验门控与提交 POST /api/voices/batches 后跳转批次页。
 */

import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

import { VoiceNewPage } from "@/features/voices/VoiceNewPage"
import { mockApiFetch, renderWithProviders } from "@/test/testUtils"
import { makeAnchorBatch, makeSpeaker } from "@/test/voiceFixtures"

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

/**
 * 打开 Radix Select 并选择选项。
 *
 * jsdom 无 PointerEvent 构造器（fireEvent.pointerDown 无法携带
 * pointerType，触发器不会展开），按 Radix 测试口径走键盘：Enter 展开、
 * click 选项（非鼠标 pointerType 路径触发选中）。
 */
function selectOption(trigger: HTMLElement, optionName: string | RegExp) {
  fireEvent.keyDown(trigger, { key: "Enter" })
  const option = screen.getByRole("option", { name: optionName })
  fireEvent.click(option)
}

describe("VoiceNewPage", () => {
  it("加载 speaker 后默认选中第一个并预填锚点文本", async () => {
    mockApiFetch({
      "/api/voices/speakers": () => [makeSpeaker()],
    })

    renderWithProviders(<VoiceNewPage />, {
      route: "/voices/new",
      path: "/voices/new",
    })

    expect(
      await screen.findByText("Ethan — Warm male narration"),
    ).toBeInTheDocument()
    const anchor = screen.getByLabelText(/锚点朗读文本/) as HTMLTextAreaElement
    expect(anchor.value).toContain("Every article deserves a clear voice")
  })

  it("提交创建批次并跳转批次页", async () => {
    const fetchMock = mockApiFetch({
      "/api/voices/speakers": () => [
        makeSpeaker(),
        makeSpeaker({ name: "Nora", description: "Bright female narration" }),
      ],
      "/api/voices/batches": () =>
        makeAnchorBatch({ batch_id: "batch-new-1", candidates: [] }),
    })

    const { router } = renderWithProviders(<VoiceNewPage />, {
      route: "/voices/new",
      path: "/voices/new",
    })

    // 切换到第二个 speaker（Radix Select 交互）。
    const trigger = await screen.findByRole("combobox", { name: "英文 Speaker" })
    selectOption(trigger, /Nora — Bright female narration/)

    fireEvent.change(screen.getByLabelText(/锚点朗读文本/), {
      target: { value: "Custom anchor line." },
    })
    fireEvent.change(screen.getByLabelText(/风格 instruct/), {
      target: { value: "Calm narration." },
    })

    fireEvent.click(
      screen.getByRole("button", { name: "加载模型并生成候选" }),
    )

    await waitFor(() => {
      const post = fetchMock.mock.calls.find(
        (call) =>
          call[0] === "/api/voices/batches" && call[1]?.method === "POST",
      )
      expect(post).toBeDefined()
      expect(JSON.parse(post![1]?.body as string)).toEqual({
        speaker: "Nora",
        anchor_text: "Custom anchor line.",
        instruct: "Calm narration.",
        seed: 0,
        count: 3,
      })
    })

    // 成功后跳转批次试听页。
    await waitFor(() => {
      expect(router.state.location.pathname).toBe("/voices/batches/batch-new-1")
    })
  })

  it("清空锚点文本时阻止提交并提示", async () => {
    const fetchMock = mockApiFetch({
      "/api/voices/speakers": () => [makeSpeaker()],
      "/api/voices/batches": () => makeAnchorBatch(),
    })

    renderWithProviders(<VoiceNewPage />, {
      route: "/voices/new",
      path: "/voices/new",
    })

    await screen.findByText("Ethan — Warm male narration")
    fireEvent.change(screen.getByLabelText(/锚点朗读文本/), {
      target: { value: "" },
    })
    fireEvent.click(
      screen.getByRole("button", { name: "加载模型并生成候选" }),
    )

    expect(await screen.findByText("请输入锚点朗读文本")).toBeInTheDocument()
    const post = fetchMock.mock.calls.find(
      (call) =>
        call[0] === "/api/voices/batches" && call[1]?.method === "POST",
    )
    expect(post).toBeUndefined()
  })

  it("Speaker 列表加载失败渲染错误提示", async () => {
    mockApiFetch({})

    renderWithProviders(<VoiceNewPage />, {
      route: "/voices/new",
      path: "/voices/new",
    })

    await waitFor(() => {
      expect(screen.getByRole("alert")).toHaveTextContent(
        "Speaker 列表加载失败",
      )
    })
  })
})
