/**
 * 富文本粘贴 → Markdown 转换（设计 §7.2）。
 *
 * `htmlToMarkdown` 是纯函数（HTML 字符串 → Markdown 字符串）：先做
 * Word / Google Docs 冗余标记的 DOM 预处理，再交给 turndown +
 * turndown-plugin-gfm（表格/删除线/任务列表/标题/列表/链接/行内代码）。
 * 编辑器侧（components/markdown/MarkdownEditor）在 clipboardData 含
 * text/html 时调用本函数，产物非空则以转换文本替换默认粘贴，否则回退
 * 纯文本——转换永不阻塞录入。
 */

import TurndownService from "turndown"
import { gfm } from "turndown-plugin-gfm"

/** Word/编辑器残留的非内容元素（含 Outlook 空段占位 `o:p`）。 */
const DROPPED_ELEMENTS = new Set([
  "style",
  "script",
  "meta",
  "link",
  "title",
  "head",
  "o:p",
])

/** 各标签保留的属性白名单：其余（style/class/id/dir/face/size…）全部清除。 */
const KEPT_ATTRIBUTES: Record<string, string[]> = {
  a: ["href"],
  code: ["class"], // language-* 由 turndown 转为围栏语言标注
  img: ["src", "alt"],
  input: ["type", "checked", "disabled"], // 任务列表复选框（gfm 插件读取属性）
  td: ["align"], // turndown-plugin-gfm 表格对齐依据
  th: ["align"],
}

function keptAttributesFor(tagName: string): string[] {
  return KEPT_ATTRIBUTES[tagName] ?? []
}

/** Google Docs 用样式承载语义（700 加粗、斜体、删除线），先转回语义标签。 */
function rewriteSemanticSpans(document: Document): void {
  const spans = Array.from(document.getElementsByTagName("span"))
  for (const span of spans) {
    const style = span.getAttribute("style") ?? ""
    const semanticName = semanticReplacement(style)
    if (!semanticName) {
      continue
    }
    const replacement = document.createElement(semanticName)
    while (span.firstChild) {
      replacement.appendChild(span.firstChild)
    }
    // 保留原 style 供后续“反义包装器解包”判断（随后统一剥离属性）。
    replacement.setAttribute("style", style)
    span.replaceWith(replacement)
  }
}

function semanticReplacement(style: string): string | null {
  // 仅当样式未把语义“关掉”（如 font-weight:normal 的 b）时才升级为标签。
  if (/(^|[^-])font-weight:\s*(700|bold)/i.test(style)) {
    return styleDowngraded(style, "font-weight") ? null : "b"
  }
  if (/font-style:\s*italic/i.test(style)) {
    return styleDowngraded(style, "font-style") ? null : "i"
  }
  if (/text-decoration[^;]*line-through/i.test(style)) {
    return styleDowngraded(style, "text-decoration") ? null : "del"
  }
  return null
}

/** 样式里是否同时存在与目标语义相反的声明（`normal`/`none`）。 */
function styleDowngraded(style: string, property: string): boolean {
  const pattern = new RegExp(`${property}\\s*:\\s*(normal|none)`, "i")
  return pattern.test(style)
}

/** 解包把语义抵消掉的包装器（GDocs 根部 `<b style="font-weight:normal">`）。 */
function unwrapNeutralizedWrappers(document: Document): void {
  const wrappers: Array<[string, RegExp]> = [
    ["b", /^font-weight:\s*normal/i],
    ["strong", /^font-weight:\s*normal/i],
    ["i", /^font-style:\s*normal/i],
    ["em", /^font-style:\s*normal/i],
  ]
  for (const [tagName, neutral] of wrappers) {
    for (const element of Array.from(document.getElementsByTagName(tagName))) {
      const style = element.getAttribute("style")
      if (style && neutral.test(style.trim())) {
        element.replaceWith(...Array.from(element.childNodes))
      }
    }
  }
}

/**
 * Word / Google Docs 表格没有 thead/th，turndown-plugin-gfm 只转换带表头行
 * 的表格（其余 keep 为原始 HTML，超出管线 GFM 子集）。把首行单元格升级为
 * th，使所有表格都产出带分隔行的 GFM 表格。
 */
function promoteHeaderlessTables(document: Document): void {
  for (const table of Array.from(document.getElementsByTagName("table"))) {
    const firstRow = table.rows[0]
    if (!firstRow || firstRow.querySelector("th")) {
      continue
    }
    for (const cell of Array.from(firstRow.cells)) {
      if (cell.tagName !== "TD") {
        continue
      }
      const headerCell = document.createElement("th")
      while (cell.firstChild) {
        headerCell.appendChild(cell.firstChild)
      }
      for (const attribute of Array.from(cell.attributes)) {
        headerCell.setAttribute(attribute.name, attribute.value)
      }
      cell.replaceWith(headerCell)
    }
  }
}

function stripAttributes(document: Document): void {
  for (const element of Array.from(document.getElementsByTagName("*"))) {
    // GDocs/Word 用 style="text-align:…" 表达列对齐；映射为 gfm 插件
    // 识别的 align 属性，随后照常进入白名单。
    if (element.tagName === "TD" || element.tagName === "TH") {
      const style = element.getAttribute("style") ?? ""
      const match = style.match(/text-align:\s*(left|center|right)/i)
      if (match && !element.hasAttribute("align")) {
        element.setAttribute("align", match[1].toLowerCase())
      }
    }
    const kept = keptAttributesFor(element.tagName.toLowerCase())
    for (const attribute of Array.from(element.attributes)) {
      if (!kept.includes(attribute.name)) {
        element.removeAttribute(attribute.name)
      }
    }
  }
}

function removeDroppedElements(document: Document): void {
  for (const element of Array.from(document.getElementsByTagName("*"))) {
    if (DROPPED_ELEMENTS.has(element.tagName.toLowerCase())) {
      element.remove()
    }
  }
}

function removeComments(document: Document): void {
  const walker = document.createTreeWalker(document, NodeFilter.SHOW_COMMENT)
  const comments: Comment[] = []
  while (walker.nextNode()) {
    comments.push(walker.currentNode as Comment)
  }
  for (const comment of comments) {
    comment.parentNode?.removeChild(comment)
  }
}

/**
 * Word 在每个单元格内套 `<p class=MsoNormal>`；段落规则会在单元格内插入
 * 空行，把表格行打散。这里把单元格内的块级 p 展平为内联内容。
 */
function flattenCellBlocks(document: Document): void {
  const cells = [
    ...Array.from(document.getElementsByTagName("td")),
    ...Array.from(document.getElementsByTagName("th")),
  ]
  for (const cell of cells) {
    for (const paragraph of Array.from(cell.getElementsByTagName("p"))) {
      paragraph.replaceWith(...Array.from(paragraph.childNodes))
    }
  }
}

/** 归一化输出：不间断空格、行尾空白、列表标记冗余空格与 3+ 连续空行。 */
function normalizeMarkdown(markdown: string): string {
  return markdown
    .replace(/\u00A0/g, " ")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/^(\s*(?:[-*+]|\d+\.) ) +/gm, "$1")
    .replace(/^(\s*(?:[-*+]|\d+\.) \[[ xX]\]) +/gm, "$1 ")
    .replace(/\n{3,}/g, "\n\n")
    .trim()
}

function createTurndownService(): TurndownService {
  const turndown = new TurndownService({
    headingStyle: "atx",
    codeBlockStyle: "fenced",
    bulletListMarker: "-",
    emDelimiter: "*",
  })
  turndown.use(gfm)
  // gfm 插件的删除线是单波浪号；管线解析器（markdown-it strikethrough）
  // 只接受 `~~text~~`，这里覆盖为 GFM 双波浪号。
  turndown.addRule("strikethrough", {
    filter: ["del", "s", "strike"],
    replacement: (content) => `~~${content}~~`,
  })
  // img 显式规则：`![alt](src)` 保留 alt（设计 §7.2 图片策略）。
  turndown.addRule("image", {
    filter: "img",
    replacement: (_content, node) => {
      const image = node as HTMLImageElement
      const alt = (image.getAttribute("alt") ?? "").replace(/[\[\]]/g, "")
      return `![${alt}](${image.getAttribute("src") ?? ""})`
    },
  })
  return turndown
}

/**
 * 剪贴板富文本 HTML → Markdown。产物为空串表示无可转换内容，调用方
 * 应回退默认纯文本粘贴（§7.2 流程图）。
 */
export function htmlToMarkdown(html: string): string {
  const trimmed = html.trim()
  if (!trimmed) {
    return ""
  }
  const parsed = new DOMParser().parseFromString(trimmed, "text/html")
  removeComments(parsed)
  removeDroppedElements(parsed)
  rewriteSemanticSpans(parsed)
  unwrapNeutralizedWrappers(parsed)
  promoteHeaderlessTables(parsed)
  flattenCellBlocks(parsed)
  stripAttributes(parsed)

  let markdown: string
  try {
    markdown = createTurndownService().turndown(parsed.body)
  } catch {
    // 转换器自身异常（畸形输入等）：按空产物处理，绝不阻塞录入。
    return ""
  }
  return normalizeMarkdown(markdown)
}

/**
 * 粘贴事件决策（§7.2 流程）：clipboardData 含 text/html 且转换产物非空
 * 时返回 Markdown 文本；否则返回 null 表示回退默认（纯文本）粘贴。
 */
export function markdownFromClipboard(
  clipboardData: Pick<DataTransfer, "getData"> | null,
): string | null {
  const html = clipboardData?.getData("text/html")
  if (!html || !html.trim()) {
    return null
  }
  const markdown = htmlToMarkdown(html)
  return markdown.length > 0 ? markdown : null
}
