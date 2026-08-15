/**
 * VoiceBatchPage 集成测试：候选逐个试听（audio src 走既有批次音频
 * 端点）、确认激活（POST confirm，可选追加到既有配置）与拒绝交互
 * （放弃批次返回总览、不发起确认）。
 */

import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

import { VoiceBatchPage } from "@/features/voices/VoiceBatchPage"
import { mockApiFetch, renderWithProviders } from "@/test/testUtils"
import { makeAnchorBatch, makeVoiceProfile } from "@/test/voiceFixtures"

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

function renderBatchPage() {
  return renderWithProviders(<VoiceBatchPage />, {
    route: "/voices/batches/batch-0001",
    path: "/voices/batches/:batchId",
  })
}

describe("VoiceBatchPage", () => {
  it("渲染批次信息与候选音频（既有批次音频端点）", async () => {
    mockApiFetch({
      "/api/voices/batches/batch-0001": () => makeAnchorBatch(),
    })

    renderBatchPage()

    expect(await screen.findByText("批次信息")).toBeInTheDocument()
    expect(screen.getAllByText(/Every article deserves/).length).toBeGreaterThan(0)

    const first = screen.getByLabelText("候选 1 音频")
    expect(first).toHaveAttribute(
      "src",
      "/api/voices/batches/batch-0001/audio/0",
    )
    const second = screen.getByLabelText("候选 2 音频")
    expect(second).toHaveAttribute(
      "src",
      "/api/voices/batches/batch-0001/audio/1",
    )
    expect(screen.getByText("冻结规则")).toBeInTheDocument()
  })

  it("确认候选走既有 confirm 端点并回声音总览", async () => {
    const fetchMock = mockApiFetch({
      "/api/voices/batches/batch-0001": () => makeAnchorBatch(),
      "/api/voices/batches/batch-0001/confirm": () =>
        makeVoiceProfile({ revision: 3 }),
    })

    const { router } = renderBatchPage()

    // 追加到既有配置 ID（可留空）→ voice_profile_id 透传。
    fireEvent.change(
      await screen.findByLabelText("追加到既有配置 ID（候选 1）"),
      { target: { value: "vp-0001" } },
    )
    fireEvent.click(screen.getByRole("button", { name: "确认候选 1" }))

    await waitFor(() => {
      const confirm = fetchMock.mock.calls.find(
        (call) =>
          typeof call[0] === "string" &&
          call[0].startsWith("/api/voices/batches/batch-0001/confirm/"),
      )
      expect(confirm).toBeDefined()
      expect(confirm![0]).toBe("/api/voices/batches/batch-0001/confirm/0")
      expect(confirm![1]?.method).toBe("POST")
      expect(JSON.parse(confirm![1]?.body as string)).toEqual({
        voice_profile_id: "vp-0001",
      })
    })

    await waitFor(() => {
      expect(router.state.location.pathname).toBe("/voices")
    })
  })

  it("留空配置 ID 确认时提交 null（创建全新配置）", async () => {
    const fetchMock = mockApiFetch({
      "/api/voices/batches/batch-0001": () => makeAnchorBatch(),
      "/api/voices/batches/batch-0001/confirm": () => makeVoiceProfile(),
    })

    renderBatchPage()

    fireEvent.click(await screen.findByRole("button", { name: "确认候选 2" }))

    await waitFor(() => {
      const confirm = fetchMock.mock.calls.find(
        (call) =>
          typeof call[0] === "string" &&
          call[0] === "/api/voices/batches/batch-0001/confirm/1",
      )
      expect(confirm).toBeDefined()
      expect(JSON.parse(confirm![1]?.body as string)).toEqual({
        voice_profile_id: null,
      })
    })
  })

  it("拒绝交互：放弃该批次仅返回总览，不发起确认", async () => {
    const fetchMock = mockApiFetch({
      "/api/voices/batches/batch-0001": () => makeAnchorBatch(),
    })

    const { router } = renderBatchPage()

    fireEvent.click(await screen.findByRole("button", { name: "放弃该批次" }))

    expect(router.state.location.pathname).toBe("/voices")
    const confirms = fetchMock.mock.calls.filter(
      (call) => typeof call[0] === "string" && call[0].includes("/confirm/"),
    )
    expect(confirms).toHaveLength(0)
  })

  it("批次不存在时渲染错误提示", async () => {
    mockApiFetch({})

    renderBatchPage()

    await waitFor(() => {
      expect(screen.getByRole("alert")).toHaveTextContent("批次加载失败")
    })
  })
})
