/**
 * VoicesPage 集成测试：激活配置卡片（锚点信息 + 音频）、修订历史
 * （激活切换交互）、候选批次链接与无配置空态引导。
 */

import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

import { VoicesPage } from "@/features/voices/VoicesPage"
import { mockApiFetch, renderWithProviders } from "@/test/testUtils"
import { makeAnchorBatch, makeVoiceProfile } from "@/test/voiceFixtures"

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

describe("VoicesPage", () => {
  it("渲染当前激活配置（锚点信息 + 音频）与修订历史", async () => {
    mockApiFetch({
      "/api/voices/profiles": () => [
        makeVoiceProfile({ revision: 1, is_active: false }),
        makeVoiceProfile({ revision: 2, is_active: true, seed: 9 }),
      ],
      "/api/voices/batches": () => [makeAnchorBatch()],
    })

    renderWithProviders(<VoicesPage />, { route: "/voices", path: "/voices" })

    // 激活配置卡片：锚点信息 + 锚点音频端点。
    expect(await screen.findByText("当前激活配置")).toBeInTheDocument()
    expect(screen.getAllByText("Ethan").length).toBeGreaterThan(0)
    expect(screen.getAllByText(/Every article deserves/).length).toBeGreaterThan(0)
    const audio = screen.getByLabelText("激活配置锚点音频")
    expect(audio).toHaveAttribute("src", "/api/voices/profiles/vp-0001/2/audio")

    // 修订历史：两条修订（激活卡片亦展示同一配置 ID），
    // 激活行带徽标、其余行提供激活按钮。
    expect(screen.getByText("修订历史")).toBeInTheDocument()
    expect(screen.getByText("vp-0001@1")).toBeInTheDocument()
    expect(screen.getAllByText("vp-0001@2")).toHaveLength(2)
    expect(screen.getByText("当前激活")).toBeInTheDocument()
    expect(
      screen.getByRole("button", { name: "设为激活" }),
    ).toBeInTheDocument()
  })

  it("点击设为激活走既有 activate 端点", async () => {
    const fetchMock = mockApiFetch({
      "/api/voices/profiles": () => [
        makeVoiceProfile({ revision: 1, is_active: false }),
        makeVoiceProfile({ revision: 2, is_active: true, seed: 9 }),
      ],
      "/api/voices/batches": () => [],
      "/api/voices/profiles/vp-0001/1/activate": () =>
        makeVoiceProfile({ revision: 1, is_active: true }),
    })

    renderWithProviders(<VoicesPage />, { route: "/voices", path: "/voices" })

    fireEvent.click(await screen.findByRole("button", { name: "设为激活" }))

    await waitFor(() => {
      const activate = fetchMock.mock.calls.find(
        (call) => call[0] === "/api/voices/profiles/vp-0001/1/activate",
      )
      expect(activate).toBeDefined()
      expect(activate![1]?.method).toBe("POST")
    })
  })

  it("候选批次链接到批次试听页", async () => {
    mockApiFetch({
      "/api/voices/profiles": () => [makeVoiceProfile()],
      "/api/voices/batches": () => [makeAnchorBatch()],
    })

    renderWithProviders(<VoicesPage />, { route: "/voices", path: "/voices" })

    const link = await screen.findByRole("link", { name: /Ethan · 2 个候选/ })
    expect(link).toHaveAttribute("href", "/voices/batches/batch-0001")
  })

  it("无配置空态引导至新建候选页", async () => {
    mockApiFetch({
      "/api/voices/profiles": () => [],
      "/api/voices/batches": () => [],
    })

    renderWithProviders(<VoicesPage />, { route: "/voices", path: "/voices" })

    expect(
      await screen.findByText("还没有已确认的声音配置"),
    ).toBeInTheDocument()
    expect(
      screen.getByText("新建锚点候选并试听确认后，生产任务才能合成语音。"),
    ).toBeInTheDocument()
    // 页头操作与空态引导都指向 /voices/new。
    const links = screen
      .getAllByRole("link", { name: "新建锚点候选" })
      .map((link) => link.getAttribute("href"))
    expect(links).toHaveLength(2)
    expect(links.every((href) => href === "/voices/new")).toBe(true)
    // 空配置时不渲染修订历史表。
    expect(screen.queryByText("修订历史")).not.toBeInTheDocument()
  })

  it("请求失败渲染错误提示", async () => {
    mockApiFetch({})

    renderWithProviders(<VoicesPage />, { route: "/voices", path: "/voices" })

    await waitFor(() => {
      expect(screen.getByRole("alert")).toHaveTextContent("声音配置加载失败")
    })
  })
})
