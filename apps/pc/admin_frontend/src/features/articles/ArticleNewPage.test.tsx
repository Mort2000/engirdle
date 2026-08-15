/**
 * 文章录入页集成测试：编辑器录入 → POST /api/articles → 跳转结构确认页。
 */

import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"

import { renderWithProviders, mockApiFetch } from "@/test/testUtils"
import { ArticleNewPage } from "@/features/articles/ArticleNewPage"

afterEach(cleanup)

describe("ArticleNewPage", () => {
  it("submits the typed article and navigates to the revision structure page", async () => {
    const fetchMock = mockApiFetch({
      "/api/articles": () => ({
        article_id: "art-0042",
        revision: 1,
        title: "Typed title",
        status: "structured",
        source_sha256: "s",
        normalized_sha256: "n",
        structure_sha256: "t",
        raw_text: "Body sentence.",
        source: { author: null, display_name: null, url: null, license_name: "unknown" },
        blocks: [],
      }),
    })

    const { router } = renderWithProviders(<ArticleNewPage />, {
      route: "/articles/new",
      path: "/articles/new",
    })

    fireEvent.change(screen.getByLabelText("标题"), {
      target: { value: "Typed title" },
    })
    // 正文经 CodeMirror 粘贴接管写入（同时覆盖粘贴转换集成路径）。
    const content = document.querySelector(".cm-content") as HTMLElement
    content.focus()
    const pasteEvent = new Event("paste", { bubbles: true, cancelable: true })
    Object.defineProperty(pasteEvent, "clipboardData", {
      value: {
        getData: (type: string) =>
          type === "text/html" ? "<p><strong>Body sentence.</strong></p>" : "",
      },
    })
    content.dispatchEvent(pasteEvent)

    fireEvent.click(screen.getByRole("button", { name: "保存并生成候选结构" }))

    await waitFor(() => {
      const post = fetchMock.mock.calls.find(
        (call) => call[0] === "/api/articles" && call[1]?.method === "POST",
      )
      expect(post).toBeDefined()
      expect(JSON.parse(post![1]?.body as string)).toMatchObject({
        title: "Typed title",
        body: "**Body sentence.**",
        license_name: "unknown",
      })
    })

    // 成功后跳转该修订的结构确认页（§7.3 衔接）。
    await waitFor(() => {
      expect(router.state.location.pathname).toBe("/articles/art-0042/revisions/1")
    })
  })

  it("blocks submission when required fields are missing", async () => {
    const fetchMock = mockApiFetch({ "/api/articles": () => ({}) })

    renderWithProviders(<ArticleNewPage />, {
      route: "/articles/new",
      path: "/articles/new",
    })

    fireEvent.click(screen.getByRole("button", { name: "保存并生成候选结构" }))

    expect(await screen.findByText("请输入标题")).toBeInTheDocument()
    expect(screen.getByText("请输入英文 Markdown 正文")).toBeInTheDocument()
    expect(fetchMock).not.toHaveBeenCalledWith(
      "/api/articles",
      expect.anything(),
    )
  })
})
