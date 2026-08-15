/**
 * Markdown 录入编辑器（设计 §7.1）：
 * - CodeMirror 6（@uiw/react-codemirror）+ @codemirror/lang-markdown，
 *   base markdownLanguage 内建 GFM（表格/删除线/任务列表/自动链接）解析
 *   与高亮；
 * - 主题基于 §6.2 token（editorTheme.ts），颜色走 CSS 变量随亮暗联动；
 * - 粘贴接管（§7.2）：clipboardData 含 text/html 时经 lib/paste 转换，
 *   非空则替换默认粘贴（可 Ctrl+Z 撤销）并 Toast 提示；失败/为空回退
 *   纯文本，绝不阻塞录入；
 * - 字数/句数统计（lib/markdownStats）展示于编辑器下缘。
 */

import { useMemo } from "react"
import CodeMirror from "@uiw/react-codemirror"
import { EditorView } from "@codemirror/view"
import { markdown, markdownLanguage } from "@codemirror/lang-markdown"
import { toast } from "sonner"

import { markdownFromClipboard } from "@/lib/paste"
import { markdownStats } from "@/lib/markdownStats"
import {
  engirdleEditorTheme,
  engirdleProseTypography,
  engirdleSyntaxHighlighting,
} from "@/components/markdown/editorTheme"

export interface MarkdownEditorProps {
  value: string
  onChange: (value: string) => void
  /** 无内容时的占位提示。 */
  placeholder?: string
  /** 编辑区最小高度（px），默认 420。 */
  minHeight?: number
  /** 无障碍标签（同时用作测试定位）。 */
  label: string
}

export function MarkdownEditor({
  value,
  onChange,
  placeholder,
  minHeight = 420,
  label,
}: MarkdownEditorProps) {
  // 粘贴处理走 CodeMirror DOM 事件句柄扩展（§7.2 流程图）。
  const pasteExtension = useMemo(
    () =>
      EditorView.domEventHandlers({
        paste: (event, view) => {
          const markdownText = markdownFromClipboard(
            event.clipboardData as Pick<DataTransfer, "getData"> | null,
          )
          if (markdownText === null) {
            return false // 无富文本或转换产物为空：默认（纯文本）粘贴。
          }
          view.dispatch(view.state.replaceSelection(markdownText))
          toast.success("富文本已转换为 Markdown")
          return true
        },
      }),
    [],
  )

  const extensions = useMemo(
    () => [
      markdown({ base: markdownLanguage, addKeymap: true }),
      engirdleSyntaxHighlighting,
      engirdleProseTypography,
      pasteExtension,
    ],
    [pasteExtension],
  )

  const stats = useMemo(() => markdownStats(value), [value])

  return (
    <div className="space-y-1.5">
      <div
        className="overflow-hidden rounded-lg border bg-card"
        data-testid="markdown-editor"
        aria-label={label}
      >
        <CodeMirror
          value={value}
          onChange={onChange}
          extensions={extensions}
          // 主题颜色全走 §6.2 CSS 变量（editorTheme.ts），`.dark` 切换
          // 时自动联动，无需按亮暗重建编辑器。
          theme={engirdleEditorTheme}
          placeholder={placeholder}
          minHeight={`${minHeight}px`}
          basicSetup={{
            lineNumbers: false,
            foldGutter: false,
            highlightActiveLine: true,
            bracketMatching: false,
            closeBrackets: false,
            autocompletion: false,
            highlightSelectionMatches: false,
          }}
          aria-label={label}
        />
      </div>
      <p className="text-right text-xs tabular-nums text-muted-foreground">
        {stats.words} 词 · {stats.sentences} 句
      </p>
    </div>
  )
}
