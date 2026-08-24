# components/markdown/

Markdown 录入组件（设计 §7）：

- `MarkdownEditor.tsx` — CodeMirror 6 编辑器（`@uiw/react-codemirror` +
  `@codemirror/lang-markdown`，base `markdownLanguage` 内建 GFM 扩展），
  `EditorView.lineWrapping` 软换行（长段/超长 token 折行，编辑器不随文本
  水平扩张），粘贴接管（§7.2：富文本自动转 Markdown，失败回退纯文本）与
  字数/句数统计（`lib/markdownStats`）。
- `editorTheme.ts` — 编辑器主题与 GFM token 高亮，颜色全部引用 §6.2
  token 的 CSS 变量，随亮暗主题自动联动；字号/行高按正文阅读优化。
