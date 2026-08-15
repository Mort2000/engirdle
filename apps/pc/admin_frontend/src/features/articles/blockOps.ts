/**
 * 结构块编辑纯操作：句级拆分点决策与块合并资格判定（设计 §7.3）。
 * 独立成模块以便单测与组件文件保持 fast-refresh 纯净。
 */

import type {
  EditedBlockPayload,
  TextEditedBlockPayload,
} from "@/features/articles/editedBlockSchema"

const TERMINATOR_PATTERN = /[.!?…]+[”"’)»]?\s*/g

export function isTextBlock(
  block: EditedBlockPayload,
): block is TextEditedBlockPayload {
  return (
    block.kind === "paragraph" ||
    block.kind === "heading" ||
    block.kind === "list_item" ||
    block.kind === "quote"
  )
}

/** 同类且关键参数一致才可合并（合并块沿用上一块的样式参数）。 */
export function canMergeIntoPrevious(
  previous: EditedBlockPayload,
  current: EditedBlockPayload,
): boolean {
  if (!isTextBlock(previous) || !isTextBlock(current)) {
    return false
  }
  if (previous.kind !== current.kind) {
    return false
  }
  if (previous.kind === "heading" && current.kind === "heading") {
    return previous.level === current.level
  }
  if (previous.kind === "list_item" && current.kind === "list_item") {
    return (
      previous.list_kind === current.list_kind &&
      previous.list_depth === current.list_depth
    )
  }
  return true
}

/**
 * 句子拆分点决策：优先光标位置；其次最后一个句末标点之后；再次最接近
 * 中点的词边界；无法得到两个非空半句时返回 null。
 */
export function splitSentenceAt(
  text: string,
  cursor: number | null,
): { first: string; second: string } | null {
  const candidates: number[] = []
  if (cursor !== null && cursor > 0 && cursor < text.length) {
    candidates.push(cursor)
  }
  let lastTerminator = -1
  for (const match of text.matchAll(TERMINATOR_PATTERN)) {
    const end = (match.index ?? 0) + match[0].length
    if (end > 0 && end < text.length) {
      lastTerminator = end
    }
  }
  if (lastTerminator > 0) {
    candidates.push(lastTerminator)
  }
  const middle = Math.floor(text.length / 2)
  let wordBoundary = -1
  let bestDistance = Number.POSITIVE_INFINITY
  for (const match of text.matchAll(/\s+/g)) {
    const boundary = (match.index ?? 0) + match[0].length
    const distance = Math.abs(boundary - middle)
    if (boundary > 0 && boundary < text.length && distance < bestDistance) {
      bestDistance = distance
      wordBoundary = boundary
    }
  }
  if (wordBoundary > 0) {
    candidates.push(wordBoundary)
  }
  for (const position of candidates) {
    const first = text.slice(0, position).trim()
    const second = text.slice(position).trim()
    if (first.length > 0 && second.length > 0) {
      return { first, second }
    }
  }
  return null
}
