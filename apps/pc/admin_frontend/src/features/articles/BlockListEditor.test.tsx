/**
 * BlockListEditor 组件测试（本阶段 spec 第 4 项：编辑/合并/拆分/重排/
 * 表格 cell）+ blockOps 纯函数单测。
 */

import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

import { BlockListEditor } from "@/features/articles/BlockListEditor"
import type { EditedBlockPayload } from "@/features/articles/editedBlockSchema"
import {
  canMergeIntoPrevious,
  splitSentenceAt,
} from "@/features/articles/blockOps"

function makeBlocks(): EditedBlockPayload[] {
  return [
    {
      kind: "paragraph",
      block_id: "blk-1",
      sentences: [
        { sentence_id: "s-1", text: "One sentence. Another part." },
        { sentence_id: "s-2", text: "Second sentence." },
      ],
    },
    {
      kind: "paragraph",
      block_id: "blk-2",
      sentences: [{ sentence_id: "s-3", text: "Third sentence." }],
    },
    {
      kind: "table",
      block_id: "blk-3",
      alignments: ["left", "center"],
      header: ["H1", "H2"],
      rows: [["a", "b"]],
    },
    { kind: "divider", block_id: "blk-4" },
  ]
}

function renderEditor(
  onSave: (payload: unknown) => Promise<void>,
  blocks: EditedBlockPayload[] = makeBlocks(),
) {
  return render(
    <BlockListEditor blocks={blocks} onSave={onSave} saving={false} />,
  )
}

afterEach(cleanup)

describe("BlockListEditor · 句级编辑", () => {
  it("edits sentence text and submits the updated payload", async () => {
    const onSave = vi.fn().mockResolvedValue(undefined)
    renderEditor(onSave)

    fireEvent.change(screen.getByLabelText("句子 1-1"), {
      target: { value: "Edited opening sentence." },
    })
    fireEvent.click(screen.getByRole("button", { name: "保存结构" }))

    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    const payload = onSave.mock.calls[0]![0] as { blocks: EditedBlockPayload[] }
    expect(payload.blocks[0]).toMatchObject({
      kind: "paragraph",
      block_id: "blk-1",
      sentences: [
        { sentence_id: "s-1", text: "Edited opening sentence." },
        { sentence_id: "s-2", text: "Second sentence." },
      ],
    })
  })

  it("blocks save with an in-page alert when a sentence is empty", async () => {
    const onSave = vi.fn().mockResolvedValue(undefined)
    renderEditor(onSave)

    fireEvent.change(screen.getByLabelText("句子 1-1"), {
      target: { value: "" },
    })
    fireEvent.click(screen.getByRole("button", { name: "保存结构" }))

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "结构校验未通过",
    )
    expect(onSave).not.toHaveBeenCalled()
  })
})

describe("BlockListEditor · 拆分", () => {
  it("splits a sentence after its last sentence terminator", async () => {
    const onSave = vi.fn().mockResolvedValue(undefined)
    renderEditor(onSave)

    fireEvent.click(screen.getByRole("button", { name: "拆分句子 1-1" }))
    fireEvent.click(screen.getByRole("button", { name: "保存结构" }))

    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    const payload = onSave.mock.calls[0]![0] as { blocks: EditedBlockPayload[] }
    expect(payload.blocks[0]).toMatchObject({
      sentences: [
        { sentence_id: "s-1", text: "One sentence." },
        { sentence_id: null, text: "Another part." },
        { sentence_id: "s-2", text: "Second sentence." },
      ],
    })
  })

  it("merges a sentence into its previous sentence", async () => {
    const onSave = vi.fn().mockResolvedValue(undefined)
    renderEditor(onSave)

    fireEvent.click(
      screen.getByRole("button", { name: "合并句子 1-2 到上一句" }),
    )
    fireEvent.click(screen.getByRole("button", { name: "保存结构" }))

    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    const payload = onSave.mock.calls[0]![0] as { blocks: EditedBlockPayload[] }
    expect(payload.blocks[0]).toMatchObject({
      sentences: [
        {
          sentence_id: "s-1",
          text: "One sentence. Another part. Second sentence.",
        },
      ],
    })
  })
})

describe("BlockListEditor · 块级", () => {
  it("reorders blocks with the move buttons", async () => {
    const onSave = vi.fn().mockResolvedValue(undefined)
    renderEditor(onSave)

    fireEvent.click(screen.getByRole("button", { name: "上移块 2" }))
    fireEvent.click(screen.getByRole("button", { name: "保存结构" }))

    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    const payload = onSave.mock.calls[0]![0] as { blocks: EditedBlockPayload[] }
    expect(payload.blocks.map((block) => block.block_id)).toEqual([
      "blk-2",
      "blk-1",
      "blk-3",
      "blk-4",
    ])
    // 句子身份随块一起移动。
    expect(payload.blocks[0]).toMatchObject({
      sentences: [{ sentence_id: "s-3", text: "Third sentence." }],
    })
  })

  it("merges a compatible block into the previous one", async () => {
    const onSave = vi.fn().mockResolvedValue(undefined)
    renderEditor(onSave)

    fireEvent.click(screen.getByRole("button", { name: "合并块 2 到上一块" }))
    fireEvent.click(screen.getByRole("button", { name: "保存结构" }))

    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    const payload = onSave.mock.calls[0]![0] as { blocks: EditedBlockPayload[] }
    expect(payload.blocks.map((block) => block.block_id)).toEqual([
      "blk-1",
      "blk-3",
      "blk-4",
    ])
    expect(payload.blocks[0]).toMatchObject({
      kind: "paragraph",
      sentences: [
        { sentence_id: "s-1" },
        { sentence_id: "s-2" },
        { sentence_id: "s-3" },
      ],
    })
  })

  it("hides merge for blocks with incompatible kinds", () => {
    renderEditor(vi.fn(), [
      { kind: "divider", block_id: "blk-d" },
      {
        kind: "paragraph",
        block_id: "blk-p",
        sentences: [{ sentence_id: "s-1", text: "Text." }],
      },
    ])

    expect(
      screen.queryByRole("button", { name: "合并块 2 到上一块" }),
    ).not.toBeInTheDocument()
  })
})

describe("BlockListEditor · 表格 cell", () => {
  it("edits header cells, body cells and column alignment", async () => {
    const onSave = vi.fn().mockResolvedValue(undefined)
    renderEditor(onSave)

    fireEvent.change(screen.getByLabelText("块 3 表头列 1"), {
      target: { value: "Feature" },
    })
    fireEvent.change(screen.getByLabelText("块 3 行 1 列 2"), {
      target: { value: "42" },
    })
    fireEvent.click(screen.getByRole("button", { name: "保存结构" }))

    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    const payload = onSave.mock.calls[0]![0] as { blocks: EditedBlockPayload[] }
    expect(payload.blocks[2]).toMatchObject({
      kind: "table",
      header: ["Feature", "H2"],
      rows: [["a", "42"]],
      alignments: ["left", "center"],
    })
  })
})

describe("blockOps · 纯函数", () => {
  it("prefers the recorded cursor position for splits", () => {
    expect(splitSentenceAt("alpha beta gamma", 6)).toEqual({
      first: "alpha",
      second: "beta gamma",
    })
  })

  it("falls back to the last terminator, then to a word boundary", () => {
    expect(splitSentenceAt("One. Two. Three.", null)).toEqual({
      first: "One. Two.",
      second: "Three.",
    })
    expect(splitSentenceAt("no terminators here", null)).toEqual({
      first: "no",
      second: "terminators here",
    })
  })

  it("refuses to split unsplittable text", () => {
    expect(splitSentenceAt("word", null)).toBeNull()
    expect(splitSentenceAt("", null)).toBeNull()
  })

  it("judges merge compatibility by kind and parameters", () => {
    const paragraph = {
      kind: "paragraph",
      block_id: "a",
      sentences: [{ sentence_id: null, text: "x." }],
    } as EditedBlockPayload
    const sameParagraph = {
      kind: "paragraph",
      block_id: "b",
      sentences: [{ sentence_id: null, text: "y." }],
    } as EditedBlockPayload
    const table = {
      kind: "table",
      block_id: "c",
      alignments: ["left"],
      header: ["h"],
      rows: [],
    } as EditedBlockPayload

    expect(canMergeIntoPrevious(paragraph, sameParagraph)).toBe(true)
    expect(canMergeIntoPrevious(paragraph, table)).toBe(false)
    expect(canMergeIntoPrevious(table, paragraph)).toBe(false)
  })
})
