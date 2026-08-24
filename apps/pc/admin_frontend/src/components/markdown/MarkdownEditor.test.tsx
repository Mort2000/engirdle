/**
 * MarkdownEditor 冒烟测试（本阶段 spec：渲染与统计）+ 粘贴接管行为。
 * 交互经 CodeMirror contentDOM 上的原生 paste 事件驱动（jsdom 不合成
 * contentEditable 键盘输入）。
 */

import { cleanup, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

import { MarkdownEditor } from "@/components/markdown/MarkdownEditor"
import { ThemeProvider } from "@/lib/theme"

function renderEditor(
  value: string,
  onChange: (value: string) => void,
): ReturnType<typeof render> {
  return render(
    <ThemeProvider>
      <MarkdownEditor value={value} onChange={onChange} label="英文 Markdown" />
    </ThemeProvider>,
  )
}

function dispatchPaste(html: string | null, plain: string): Event {
  const content = document.querySelector(".cm-content") as HTMLElement
  content.focus()
  const pasteEvent = new Event("paste", { bubbles: true, cancelable: true })
  Object.defineProperty(pasteEvent, "clipboardData", {
    value: {
      getData: (type: string) =>
        type === "text/html" ? (html ?? "") : plain,
    },
  })
  content.dispatchEvent(pasteEvent)
  return pasteEvent
}

afterEach(cleanup)

describe("MarkdownEditor", () => {
  it("renders the codemirror surface with gfm content", () => {
    renderEditor("# Title\n\nA paragraph with **bold**.", vi.fn())

    const editor = document.querySelector(".cm-content")
    expect(editor).not.toBeNull()
    // jsdom 下 CodeMirror 仍把文档渲染进 contentDOM。
    expect(editor?.textContent).toContain("A paragraph with")
    expect(editor?.textContent).toContain("bold")
  })

  it("enables line wrapping so long text folds instead of expanding", () => {
    renderEditor("A very long paragraph that must fold inside the editor.", vi.fn())

    // lineWrapping 扩展给 contentDOM 挂 cm-lineWrapping 类（基础主题据此
    // 应用 break-spaces + overflow-wrap: anywhere），防止长文本横向撑爆页面。
    const content = document.querySelector(".cm-content")
    expect(content).toHaveClass("cm-lineWrapping")
  })

  it("shows word and sentence counts for the current value", () => {
    renderEditor("First sentence. Second sentence, with more words!", vi.fn())

    expect(screen.getByText("7 词 · 2 句")).toBeInTheDocument()
  })

  it("shows zero stats for an empty document", () => {
    renderEditor("", vi.fn())

    expect(screen.getByText("0 词 · 0 句")).toBeInTheDocument()
  })

  it("converts pasted rich text and replaces the default paste", async () => {
    const onChange = vi.fn()
    renderEditor("", onChange)

    const pasteEvent = dispatchPaste(
      "<meta charset='utf-8'><b style=\"font-weight:normal;\"><span style=\"font-weight:700;\">Pasted bold.</span> plain tail.</b>",
      "Pasted bold. plain tail.",
    )

    // 接管成功：preventDefault 生效且转换文本替换默认粘贴（可 Ctrl+Z）。
    expect(pasteEvent.defaultPrevented).toBe(true)
    await waitFor(() => {
      // @uiw 的 onChange 携带 (value, ViewUpdate)，只断言文档文本。
      expect(onChange.mock.calls.at(-1)?.[0]).toBe("**Pasted bold.** plain tail.")
    })
    expect(document.querySelector(".cm-content")?.textContent).toContain(
      "Pasted bold.",
    )
  })

  it("falls back to the default paste when no text/html is present", async () => {
    const onChange = vi.fn()
    renderEditor("", onChange)

    dispatchPaste(null, "plain fallback")

    // 回退纯文本：CodeMirror 自身按默认语义插入纯文本（不产生转换）。
    await waitFor(() => {
      expect(onChange.mock.calls.at(-1)?.[0]).toBe("plain fallback")
    })
    expect(
      onChange.mock.calls.some(([value]) => String(value).includes("**")),
    ).toBe(false)
  })
})
