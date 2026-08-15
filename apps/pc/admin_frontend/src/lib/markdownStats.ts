/**
 * Markdown 字数/句数统计（设计 §7.1 编辑器辅助信息）。
 *
 * 轻量近似：剔除围栏代码块与纯语法符号（非正文）后，按 Unicode 词元计
 * 词；句数为终止标点（.!?… 可带收尾引号）运行数，句尾若无终止标点且
 * 仍有正文，剩余片段计一句（“Hello world” → 1 句）。
 */

export interface MarkdownStats {
  /** 词元数（字母/数字连续段，含内部连字符与撇号）。 */
  words: number
  /** 句子数（终止标点运行 + 非空尾部片段）。 */
  sentences: number
}

const WORD_PATTERN = /[\p{L}\p{N}]+(?:['’-][\p{L}\p{N}]+)*/gu
const SENTENCE_TERMINATOR = /[.!?…]+[”"’)»]?/g
const FENCED_CODE = /```[^\n]*\n[\s\S]*?(?:```|$)/g

/** Markdown 结构符号（标题/列表/表格/强调/链接语法等）按空格处理。 */
const MARKDOWN_SYNTAX = /[|#*_>~`[\]()!:-]/g

function stripNonProse(markdown: string): string {
  return markdown.replace(FENCED_CODE, " ").replace(MARKDOWN_SYNTAX, " ")
}

export function markdownStats(text: string): MarkdownStats {
  const words = text.match(WORD_PATTERN)
  if (!words || words.length === 0) {
    return { words: 0, sentences: 0 }
  }

  const prose = stripNonProse(text)
  const terminators = prose.match(SENTENCE_TERMINATOR) ?? []
  if (terminators.length === 0) {
    return { words: words.length, sentences: prose.trim().length > 0 ? 1 : 0 }
  }
  const last = terminators.at(-1) as string
  const trailing = prose.slice(prose.lastIndexOf(last) + last.length).trim()
  return {
    words: words.length,
    sentences: terminators.length + (trailing.length > 0 ? 1 : 0),
  }
}
