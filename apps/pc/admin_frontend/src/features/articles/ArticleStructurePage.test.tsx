/**
 * ArticleStructurePage 集成测试：解析警告（琥珀 Alert）、结构树只读展示、
 * 处理计数、结构保存（PUT structure）与删除文章的 AlertDialog 确认
 * （要求输入文章 ID）。
 */

import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"

import { renderWithProviders, mockApiFetch } from "@/test/testUtils"
import type { RevisionPayload } from "@/api/articles"
import { ArticleStructurePage } from "@/features/articles/ArticleStructurePage"

function revisionPayload(status: string): RevisionPayload {
  return {
    article_id: "art-0001",
    revision: 1,
    title: "Structured article",
    status: status as RevisionPayload["status"],
    source_sha256: "sha-source",
    normalized_sha256: "sha-norm",
    structure_sha256: `sha-structure-${status}`,
    raw_text: "One sentence. Another sentence.",
    source: { author: "Ada", display_name: null, url: null, license_name: "unknown" },
    blocks: [
      {
        block_id: "blk-1",
        kind: "paragraph",
        order: 0,
        style: "paragraph",
        sentences: [
          {
            sentence_id: "s-1",
            order: 0,
            text: "One sentence.",
            runs: [],
          },
          {
            sentence_id: "s-2",
            order: 1,
            text: "Another sentence.",
            runs: [],
          },
        ],
      },
    ],
  }
}

function reportPayload() {
  return {
    article_id: "art-0001",
    revision: 1,
    warnings: [
      { code: "unclosed_code_fence", message: "代码围栏未闭合" },
    ],
    structure_tree: [
      {
        block_id: "blk-1",
        kind: "paragraph",
        translates: true,
        narrates: true,
        summary: "One sentence.",
        sentence_count: 2,
        detail: "",
      },
      {
        block_id: "blk-2",
        kind: "code",
        translates: false,
        narrates: false,
        summary: "python code block",
        detail: "12 characters",
      },
    ],
    processing_counts: {
      translated_sentences: 2,
      translated_tables: 0,
      skipped_code_blocks: 1,
      narrated_sentences: 2,
    },
  }
}

afterEach(cleanup)

describe("ArticleStructurePage", () => {
  it("shows warnings, the read-only tree, counts and saves edits via PUT", async () => {
    const fetchMock = mockApiFetch({
      "/api/articles/art-0001/revisions/1": () => revisionPayload("structured"),
      "/api/articles/art-0001/revisions/1/structure-report": () =>
        reportPayload(),
      "/api/articles/art-0001/revisions/1/structure": () =>
        revisionPayload("structured"),
    })

    renderWithProviders(<ArticleStructurePage />, {
      route: "/articles/art-0001/revisions/1",
      path: "/articles/:articleId/revisions/:revision",
    })

    // 处理计数来自 structure-report 端点。
    expect(await screen.findByText(/2 句待翻译/)).toBeInTheDocument()
    expect(screen.getByText(/1 个代码块跳过/)).toBeInTheDocument()
    expect(screen.getByText(/2 句待朗读/)).toBeInTheDocument()

    // 解析警告：琥珀 Alert（role=alert）。
    const alert = screen.getByRole("alert")
    expect(alert).toHaveTextContent("解析警告")
    expect(alert).toHaveTextContent("unclosed_code_fence — 代码围栏未闭合")

    // 结构树：派生 translates/narrates 只读展示。
    expect(screen.getByText("blk-2")).toBeInTheDocument()
    expect(screen.getAllByText("是").length).toBe(2)
    expect(screen.getAllByText("否").length).toBe(2)

    // 结构化编辑器：编辑句子并保存走 PUT .../structure。
    fireEvent.change(await screen.findByLabelText("句子 1-1"), {
      target: { value: "Edited sentence." },
    })
    fireEvent.click(screen.getByRole("button", { name: "保存结构" }))

    await waitFor(() => {
      const put = fetchMock.mock.calls.find(
        (call) => call[0] === "/api/articles/art-0001/revisions/1/structure",
      )
      expect(put).toBeDefined()
      expect(put![1]?.method).toBe("PUT")
      expect(JSON.parse(put![1]?.body as string)).toMatchObject({
        blocks: [
          {
            kind: "paragraph",
            block_id: "blk-1",
            sentences: [
              { sentence_id: "s-1", text: "Edited sentence." },
              { sentence_id: "s-2", text: "Another sentence." },
            ],
          },
        ],
      })
    })
  })

  it("guards deletion behind an alert dialog requiring the article id", async () => {
    const fetchMock = mockApiFetch({
      "/api/articles/art-0001/revisions/1": () => revisionPayload("published"),
      "/api/articles/art-0001/revisions/1/structure-report": () =>
        reportPayload(),
      "/api/articles/art-0001": () => ({
        article_id: "art-0001",
        trash_path: "/tmp/trash/art-0001",
      }),
    })

    renderWithProviders(<ArticleStructurePage />, {
      route: "/articles/art-0001/revisions/1",
      path: "/articles/:articleId/revisions/:revision",
    })

    // 已冻结修订：结构编辑器不出现，展示重建/新修订/删除入口。
    expect(
      await screen.findByRole("button", { name: "重建此修订" }),
    ).toBeInTheDocument()
    expect(
      screen.queryByRole("button", { name: "保存结构" }),
    ).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "删除本地文章" }))
    const confirmInput = await screen.findByLabelText("输入文章 ID 以确认")

    // 输入不匹配的 ID：确认按钮保持禁用。
    fireEvent.change(confirmInput, { target: { value: "wrong-id" } })
    expect(
      screen.getByRole("button", { name: "确认删除" }),
    ).toBeDisabled()

    // 输入匹配的 ID 后确认：DELETE 携带 confirmation 查询参数。
    fireEvent.change(confirmInput, { target: { value: "art-0001" } })
    fireEvent.click(screen.getByRole("button", { name: "确认删除" }))

    await waitFor(() => {
      const remove = fetchMock.mock.calls.find(
        (call) =>
          typeof call[0] === "string" &&
          call[0].startsWith("/api/articles/art-0001?confirmation="),
      )
      expect(remove).toBeDefined()
      expect(remove![1]?.method).toBe("DELETE")
      expect(remove![0]).toContain("confirmation=art-0001")
    })
  })
})
