# components/markdown/

Markdown 录入组件（后续阶段填充，设计 §7）：

- CodeMirror 6 编辑器（`@uiw/react-codemirror` + `@lezer/markdown` GFM 扩展），主题随亮/暗联动。
- 富文本粘贴转换（turndown + turndown-plugin-gfm，纯函数位于 `lib/paste.ts`）。
