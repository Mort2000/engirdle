/**
 * zod 结构编辑 schema 单测：判别键路由、边界约束与后端 422 语义的
 * 客户端前置拦截（本阶段 spec 第 4 项）。
 */

import { describe, expect, it } from "vitest"

import {
  blocksFromRevisionPayload,
  editStructureSchema,
  editedBlockSchema,
} from "@/features/articles/editedBlockSchema"
import type { RevisionPayload } from "@/api/articles"

describe("editedBlockSchema · 判别键路由", () => {
  it("accepts each kind with its kind-specific payload", () => {
    expect(
      editedBlockSchema.safeParse({
        kind: "paragraph",
        block_id: "blk-1",
        sentences: [{ sentence_id: "s-1", text: "One." }],
      }).success,
    ).toBe(true)

    expect(
      editedBlockSchema.safeParse({
        kind: "heading",
        level: 2,
        sentences: [{ sentence_id: null, text: "Title" }],
      }).success,
    ).toBe(true)

    expect(
      editedBlockSchema.safeParse({
        kind: "list_item",
        list_kind: "ordered",
        list_depth: 1,
        list_ordinal: 3,
        sentences: [{ text: "Step" }],
      }).success,
    ).toBe(true)

    expect(
      editedBlockSchema.safeParse({
        kind: "quote",
        quote_depth: 2,
        sentences: [{ text: "Quoted." }],
      }).success,
    ).toBe(true)

    expect(
      editedBlockSchema.safeParse({
        kind: "table",
        alignments: ["left", "center"],
        header: ["A", "B"],
        rows: [["1", "2"]],
      }).success,
    ).toBe(true)

    expect(
      editedBlockSchema.safeParse({
        kind: "code",
        language: "python",
        code: "x = 1",
      }).success,
    ).toBe(true)

    expect(
      editedBlockSchema.safeParse({ kind: "divider", block_id: "blk-9" })
        .success,
    ).toBe(true)
  })

  it("rejects a payload under the wrong kind (discriminated union)", () => {
    // level 属 heading：挂在 paragraph 上必须失败。
    const wrongKind = editedBlockSchema.safeParse({
      kind: "paragraph",
      level: 2,
      sentences: [{ text: "One." }],
    })
    expect(wrongKind.success).toBe(false)

    // 缺少 heading 必填 level。
    const missingLevel = editedBlockSchema.safeParse({
      kind: "heading",
      sentences: [{ text: "Title" }],
    })
    expect(missingLevel.success).toBe(false)

    // list_item 缺 list_kind。
    const missingListKind = editedBlockSchema.safeParse({
      kind: "list_item",
      sentences: [{ text: "Step" }],
    })
    expect(missingListKind.success).toBe(false)

    // 未知 kind。
    const unknownKind = editedBlockSchema.safeParse({
      kind: "image",
      sentences: [],
    })
    expect(unknownKind.success).toBe(false)
  })

  it("rejects unknown fields like pydantic extra=forbid", () => {
    const result = editedBlockSchema.safeParse({
      kind: "divider",
      block_id: "blk-1",
      mystery: true,
    })
    expect(result.success).toBe(false)
  })
})

describe("editedBlockSchema · 边界约束", () => {
  it("rejects empty sentences and blank sentence text", () => {
    const emptyList = editedBlockSchema.safeParse({
      kind: "paragraph",
      sentences: [],
    })
    expect(emptyList.success).toBe(false)

    const blankText = editedBlockSchema.safeParse({
      kind: "paragraph",
      sentences: [{ sentence_id: "s1", text: "" }],
    })
    expect(blankText.success).toBe(false)
  })

  it("rejects out-of-range level, depth and ordinal", () => {
    const level = editedBlockSchema.safeParse({
      kind: "heading",
      level: 7,
      sentences: [{ text: "T" }],
    })
    expect(level.success).toBe(false)

    const depth = editedBlockSchema.safeParse({
      kind: "list_item",
      list_kind: "bullet",
      list_depth: 5,
      sentences: [{ text: "x" }],
    })
    expect(depth.success).toBe(false)

    const ordinal = editedBlockSchema.safeParse({
      kind: "list_item",
      list_kind: "bullet",
      list_ordinal: -1,
      sentences: [{ text: "x" }],
    })
    expect(ordinal.success).toBe(false)
  })

  it("rejects tables whose rows do not match the header width", () => {
    const ragged = editedBlockSchema.safeParse({
      kind: "table",
      alignments: ["left", "left"],
      header: ["A", "B"],
      rows: [["only-one"]],
    })
    expect(ragged.success).toBe(false)

    const mismatchedAlignments = editedBlockSchema.safeParse({
      kind: "table",
      alignments: ["left"],
      header: ["A", "B"],
      rows: [["1", "2"]],
    })
    expect(mismatchedAlignments.success).toBe(false)

    const alignmentEnum = editedBlockSchema.safeParse({
      kind: "table",
      alignments: ["justify"],
      header: ["A"],
      rows: [],
    })
    expect(alignmentEnum.success).toBe(false)
  })

  it("rejects empty code bodies and blank structures", () => {
    const emptyCode = editedBlockSchema.safeParse({
      kind: "code",
      code: "",
    })
    expect(emptyCode.success).toBe(false)

    const emptyStructure = editStructureSchema.safeParse({ blocks: [] })
    expect(emptyStructure.success).toBe(false)
  })
})

describe("blocksFromRevisionPayload", () => {
  it("derives edit payloads preserving identity and kind parameters", () => {
    const revision = {
      article_id: "art-1",
      revision: 1,
      title: "T",
      status: "structured",
      source_sha256: "x",
      normalized_sha256: "x",
      structure_sha256: "x",
      raw_text: "# T\n\nBody.",
      source: { author: null, display_name: null, url: null, license_name: "unknown" },
      blocks: [
        {
          block_id: "blk-h",
          kind: "heading",
          order: 0,
          style: "heading",
          level: 2,
          sentences: [{ sentence_id: "s-1", order: 0, text: "Title here", runs: [] }],
        },
        {
          block_id: "blk-l",
          kind: "list_item",
          order: 1,
          style: "list_item",
          list_kind: "ordered",
          list_depth: 1,
          list_ordinal: 2,
          sentences: [{ sentence_id: "s-2", order: 0, text: "Step", runs: [] }],
        },
        {
          block_id: "blk-q",
          kind: "quote",
          order: 2,
          style: "quote",
          quote_depth: 3,
          sentences: [{ sentence_id: "s-3", order: 0, text: "Quoted.", runs: [] }],
        },
        {
          block_id: "blk-t",
          kind: "table",
          order: 3,
          alignments: ["center", "default"],
          header: [
            { cell_id: "c1", text: "H1", runs: [] },
            { cell_id: "c2", text: "H2", runs: [] },
          ],
          rows: [
            [
              { cell_id: "c3", text: "v1", runs: [] },
              { cell_id: "c4", text: "v2", runs: [] },
            ],
          ],
        },
        {
          block_id: "blk-c",
          kind: "code",
          order: 4,
          language: "python",
          code: "x = 1",
        },
        { block_id: "blk-d", kind: "divider", order: 5 },
      ],
    } as unknown as RevisionPayload

    const payload = { blocks: blocksFromRevisionPayload(revision) }
    expect(editStructureSchema.safeParse(payload).success).toBe(true)

    const [heading, listItem, quote, table, code, divider] = payload.blocks
    expect(heading).toMatchObject({ kind: "heading", level: 2 })
    expect(listItem).toMatchObject({
      kind: "list_item",
      list_kind: "ordered",
      list_depth: 1,
      list_ordinal: 2,
    })
    expect(quote).toMatchObject({ kind: "quote", quote_depth: 3 })
    expect(table).toMatchObject({
      kind: "table",
      alignments: ["center", "default"],
      header: ["H1", "H2"],
      rows: [["v1", "v2"]],
    })
    expect(code).toMatchObject({ kind: "code", language: "python" })
    expect(divider).toEqual({ kind: "divider", block_id: "blk-d" })
  })
})
