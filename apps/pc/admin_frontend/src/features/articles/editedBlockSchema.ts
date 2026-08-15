/**
 * 结构编辑载荷的客户端校验 schema（设计 §7.3 / §11.2）。
 *
 * 与后端 app.py 的 `EditedBlockRequest`（pydantic discriminator + extra=
 * forbid）同构：kind 判别各成员形状，未知字段客户端即拒，约束边界
 * （句长、层级深度、对齐枚举、行列一致性）与后端一致，避免提交后才
 * 收到 422。
 */

import { z } from "zod"

import type { RevisionPayload, TextBlockView } from "@/api/articles"

const blockIdSchema = z.string().min(1).max(128).nullish()

const sentenceSchema = z.strictObject({
  sentence_id: blockIdSchema,
  /** 空句子非法（后端 EditSentenceRequest min_length=1）。 */
  text: z.string().min(1).max(20_000),
})

const textBlockBase = {
  block_id: blockIdSchema,
  sentences: z.array(sentenceSchema).min(1),
}

const paragraphBlockSchema = z.strictObject({
  kind: z.literal("paragraph"),
  ...textBlockBase,
})

const headingBlockSchema = z.strictObject({
  kind: z.literal("heading"),
  ...textBlockBase,
  level: z.number().int().min(1).max(6),
})

const listItemBlockSchema = z.strictObject({
  kind: z.literal("list_item"),
  ...textBlockBase,
  list_kind: z.enum(["bullet", "ordered"]),
  list_depth: z.number().int().min(0).max(4),
  list_ordinal: z.number().int().min(0).max(2_147_483_647).nullish(),
})

const quoteBlockSchema = z.strictObject({
  kind: z.literal("quote"),
  ...textBlockBase,
  quote_depth: z.number().int().min(1).max(4),
})

const tableBlockSchema = z
  .strictObject({
    kind: z.literal("table"),
    block_id: blockIdSchema,
    alignments: z.array(z.enum(["default", "left", "center", "right"])).min(1),
    header: z.array(z.string()).min(1),
    rows: z.array(z.array(z.string())).default([]),
  })
  .refine(
    (block) =>
      block.alignments.length === block.header.length &&
      block.rows.every((row) => row.length === block.header.length),
    { message: "表格每行（含表头）的列数必须与对齐配置一致" },
  )

const codeBlockSchema = z.strictObject({
  kind: z.literal("code"),
  block_id: blockIdSchema,
  language: z.string().min(1).max(64).nullish(),
  code: z.string().min(1),
})

const dividerBlockSchema = z.strictObject({
  kind: z.literal("divider"),
  block_id: blockIdSchema,
})

/** 与后端 EditedBlockRequest 判别联合同构（kind 为判别键）。 */
export const editedBlockSchema = z.discriminatedUnion("kind", [
  paragraphBlockSchema,
  headingBlockSchema,
  listItemBlockSchema,
  quoteBlockSchema,
  tableBlockSchema,
  codeBlockSchema,
  dividerBlockSchema,
])

/** PUT .../structure 请求体（EditStructureRequest 同构）。 */
export const editStructureSchema = z.strictObject({
  blocks: z.array(editedBlockSchema).min(1),
})

export type EditedBlockPayload = z.infer<typeof editedBlockSchema>

export type EditStructurePayload = z.infer<typeof editStructureSchema>

export type TextEditedBlockPayload = Extract<
  EditedBlockPayload,
  { sentences: unknown }
>

/**
 * 从修订详情（服务端块视图）派生结构编辑载荷：文本块保留句子身份与
 * 样式参数，表格降为纯文本网格（cell runs 非结构编辑关注点）。
 */
export function blocksFromRevisionPayload(
  revision: RevisionPayload,
): EditedBlockPayload[] {
  const blocks: EditedBlockPayload[] = []
  for (const block of revision.blocks) {
    switch (block.kind) {
      case "paragraph":
        blocks.push({
          kind: "paragraph",
          block_id: block.block_id,
          sentences: sentencesOf(block),
        })
        break
      case "heading":
        blocks.push({
          kind: "heading",
          block_id: block.block_id,
          sentences: sentencesOf(block),
          level: block.level ?? 1,
        })
        break
      case "list_item": {
        const listItem: EditedBlockPayload = {
          kind: "list_item",
          block_id: block.block_id,
          sentences: sentencesOf(block),
          list_kind: block.list_kind ?? "bullet",
          list_depth: block.list_depth ?? 0,
        }
        if (block.list_ordinal !== null && block.list_ordinal !== undefined) {
          blocks.push({ ...listItem, list_ordinal: block.list_ordinal })
        } else {
          blocks.push(listItem)
        }
        break
      }
      case "quote":
        blocks.push({
          kind: "quote",
          block_id: block.block_id,
          sentences: sentencesOf(block),
          quote_depth: block.quote_depth ?? 1,
        })
        break
      case "table":
        blocks.push({
          kind: "table",
          block_id: block.block_id,
          alignments: [...block.alignments],
          header: block.header.map((cell) => cell.text),
          rows: block.rows.map((row) => row.map((cell) => cell.text)),
        })
        break
      case "code":
        blocks.push({
          kind: "code",
          block_id: block.block_id,
          language: block.language,
          code: block.code,
        })
        break
      case "divider":
        blocks.push({ kind: "divider", block_id: block.block_id })
        break
    }
  }
  return blocks
}

function sentencesOf(block: TextBlockView): {
  sentence_id: string | null
  text: string
}[] {
  return block.sentences.map((sentence) => ({
    sentence_id: sentence.sentence_id,
    text: sentence.text,
  }))
}
