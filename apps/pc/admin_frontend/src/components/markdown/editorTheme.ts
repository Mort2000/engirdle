/**
 * CodeMirror 主题（设计 §6.2 / §7.1）：基于 token 变量自定义，
 * 颜色全部引用 globals.css 的 CSS 变量，`.dark` 切换时自动联动，
 * 无需重建编辑器；字号 15px / 行高 1.75 按正文阅读优化（非 IDE 风格）。
 */

import { createTheme } from "@uiw/codemirror-themes"
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language"
import { EditorView } from "@codemirror/view"
import { tags as t } from "@lezer/highlight"

/** 编辑器 chrome（背景/选区/光标）：透明背景融入卡片，其余走 token。 */
export const engirdleEditorTheme = createTheme({
  theme: "light",
  settings: {
    background: "transparent",
    backgroundImage: "",
    foreground: "var(--foreground)",
    caret: "var(--primary)",
    selection: "var(--accent)",
    selectionMatch: "var(--secondary)",
    lineHighlight: "var(--muted)",
    gutterBackground: "transparent",
    gutterForeground: "var(--muted-foreground)",
    fontFamily: "var(--font-sans)",
  },
  styles: [],
})

/** GFM 语法 token → §6.2 token 色（CSS 变量随亮暗主题翻转）。 */
export const engirdleHighlightStyle = HighlightStyle.define([
  { tag: t.heading, color: "var(--primary)", fontWeight: "600" },
  { tag: t.heading1, fontSize: "1.35em", fontWeight: "700" },
  { tag: t.heading2, fontSize: "1.22em", fontWeight: "700" },
  { tag: t.heading3, fontSize: "1.12em", fontWeight: "600" },
  { tag: t.strong, fontWeight: "700" },
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: t.strikethrough, textDecoration: "line-through", color: "var(--muted-foreground)" },
  { tag: t.link, color: "var(--primary)", textDecoration: "underline" },
  { tag: t.url, color: "var(--primary)" },
  { tag: t.monospace, fontFamily: "var(--font-mono)", color: "var(--muted-foreground)" },
  { tag: t.quote, color: "var(--muted-foreground)", fontStyle: "italic" },
  { tag: t.list, color: "var(--muted-foreground)" },
  { tag: t.processingInstruction, color: "var(--muted-foreground)" },
  { tag: t.meta, color: "var(--muted-foreground)" },
])

/** 语法高亮扩展（主题 chrome 与 token 高亮各自独立注册）。 */
export const engirdleSyntaxHighlighting = syntaxHighlighting(engirdleHighlightStyle)

/** 正文阅读字号/行高（§7.1）：非 IDE 风格的长文阅读参数。 */
export const engirdleProseTypography = EditorView.theme({
  "&": { fontSize: "15px" },
  ".cm-content": { lineHeight: "1.75" },
  ".cm-line": { padding: "0 2px" },
})
