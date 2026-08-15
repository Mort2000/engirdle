/**
 * htmlToMarkdown 单测（设计 §11：Word 导出 / Google Docs / 网页复制
 * 三类真实 HTML 样本，内联 fixture 覆盖 §7.2 全部转换语义）。
 */

import { describe, expect, it } from "vitest"

import { htmlToMarkdown, markdownFromClipboard } from "@/lib/paste"

/** Word「保留源格式」粘贴的真实形态：mso 样式、o:p 占位、条件注释。 */
const WORD_HTML = `<html xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:w="urn:schemas-microsoft-com:office:word">
<head><meta charset=utf-8><title>Exported Doc</title><style>p.MsoNormal { margin: 0; }</style></head>
<body lang=EN-US style='word-wrap:break-word'>
<div class=WordSection1>
<h1 style='margin-right:0in;margin-left:0in'><span style='font-family:"Calibri Light",sans-serif'>Quarterly Review</span></h1>
<p class=MsoNormal style='margin-bottom:8.0pt'><span style='font-size:11.0pt;font-family:"Calibri",sans-serif'>Revenue grew strongly.<o:p></o:p></span></p>
<p class=MsoNormal><b><span style='font-size:11.0pt'>Bold figures</span></b><span style='font-size:11.0pt'> and <i>italic notes</i> plus <s>old targets</s>.</span></p>
<ul type=disc>
<li class=MsoListParagraph style='mso-list:l0 level1 lfo1'>First bullet<o:p></o:p></li>
<li class=MsoListParagraph style='mso-list:l0 level1 lfo1'>Second bullet</li>
</ul>
<table class=MsoTableGrid border=1 cellspacing=0 cellpadding=0 style='border-collapse:collapse'>
<tr>
<td width=87 valign=top style='width:65.0pt;padding:0in 5.4pt 0in 5.4pt'><p class=MsoNormal><span style='font-size:11.0pt'>Region</span></p></td>
<td width=87 valign=top style='width:65.0pt;padding:0in 5.4pt 0in 5.4pt'><p class=MsoNormal><span style='font-size:11.0pt'>Growth</span></p></td>
</tr>
<tr>
<td width=87 valign=top style='width:65.0pt'><p class=MsoNormal><span style='font-size:11.0pt'>EMEA</span></p></td>
<td width=87 valign=top style='width:65.0pt'><p class=MsoNormal><span style='font-size:11.0pt'>12%</span></p></td>
</tr>
</table>
<!-- conditional comment from Word --><!--[if !supportLists]--><p class=MsoNormal><span>&nbsp;</span></p>
</div></body></html>`

/** Google Docs 粘贴的真实形态：docs-internal-guid 外层 b 包装 + 样式化 span。 */
const GOOGLE_DOCS_HTML = `<meta charset='utf-8'><b style="font-weight:normal;" id="docs-internal-guid-8f2c19e0-7ffd-4a91><span style="font-size:11pt;font-family:Arial;color:#000000;background-color:transparent;font-weight:400;font-style:normal;font-variant:normal;text-decoration:none;vertical-align:baseline;white-space:pre;white-space:pre-wrap;">Meeting notes follow.</span><span style="font-weight:700;">Decision items</span><span style="font-size:11pt;font-weight:400;"> are </span><span style="font-style:italic;">pending review</span><span style="text-decoration:line-through;">and dropped</span><span style="font-size:11pt;">. See the <a href="https://docs.example.com/minutes" style="text-decoration:none;"><span style="font-size:11pt;">minutes</span></a>.</span><h1 style="margin:0pt 0pt 6pt;"><span style="font-size:17pt;font-weight:400;">Attendees</span></h1><ul style="margin:0pt;padding:0pt 0pt 0pt 40pt;"><li dir=ltr style="list-style-type:disc"><p dir=ltr style="line-height:1.38;"><span style="font-size:11pt;">Alice</span></p></li><li dir=ltr style="list-style-type:disc"><p dir=ltr style="line-height:1.38;"><span style="font-size:11pt;">Bob</span></p></li></ul><table><tbody><tr><td style="border:1px solid rgb(0,0,0);"><span style="font-size:11pt;">Topic</span></td><td style="border:1px solid rgb(0,0,0);"><span style="font-size:11pt;">Owner</span></td></tr><tr><td style="border:1px solid rgb(0,0,0);"><span style="font-size:11pt;">Budget</span></td><td style="border:1px solid rgb(0,0,0);"><span style="font-size:11pt;">Alice</span></td></tr></tbody></table></b>`

/** 网页（GitHub 风格）复制的真实形态：任务列表、删除线、围栏代码、表格。 */
const WEB_COPY_HTML = `<h2>Migration <em>guide</em></h2>
<p>Use <strong>bold</strong>, <em>italic</em>, <code>inline_code()</code>, <del>legacy flags</del>, and a <a href="https://example.com/docs">reference link</a>.</p>
<ul>
<li><input checked="" disabled="" type="checkbox"> done task</li>
<li><input disabled="" type="checkbox"> open task</li>
</ul>
<pre><code class="language-python">def migrate():
    return 42
</code></pre>
<table>
<thead>
<tr><th align="center">Feature</th><th>Status</th></tr>
</thead>
<tbody>
<tr><td align="center">Tables</td><td>yes</td></tr>
<tr><td align="center">Autolinks</td><td>https://example.com</td></tr>
</tbody>
</table>
<p><img src="https://example.com/diagram.png" alt="Architecture diagram" width="600"> ends the sample.</p>`

describe("htmlToMarkdown · Word 导出样本", () => {
  it("cleans mso styles, o:p tags and comments while keeping semantics", () => {
    const markdown = htmlToMarkdown(WORD_HTML)

    expect(markdown).toContain("# Quarterly Review")
    expect(markdown).toContain("Revenue grew strongly.")
    expect(markdown).toContain("**Bold figures** and *italic notes* plus ~~old targets~~.")
    expect(markdown).toContain("- First bullet")
    expect(markdown).toContain("- Second bullet")
    expect(markdown).toContain("| Region | Growth |")
    expect(markdown).toContain("| EMEA | 12% |")

    // 冗余标记不得外泄。
    expect(markdown).not.toContain("Mso")
    expect(markdown).not.toContain("o:p")
    expect(markdown).not.toContain("style=")
    expect(markdown).not.toContain("class=")
    expect(markdown).not.toContain("font-size")
    expect(markdown).not.toMatch(/<!--/)
  })
})

describe("htmlToMarkdown · Google Docs 样本", () => {
  it("unwraps the neutral b wrapper and rebuilds styled spans as marks", () => {
    const markdown = htmlToMarkdown(GOOGLE_DOCS_HTML)

    expect(markdown).toContain("Meeting notes follow.")
    // font-weight:700 span → 加粗；不是整段加粗（外层 b 已解包）。
    expect(markdown).toContain("**Decision items**")
    expect(markdown.startsWith("Meeting notes follow.")).toBe(true)
    expect(markdown).toContain("*pending review*")
    expect(markdown).toContain("~~and dropped~~")
    expect(markdown).toContain("[minutes](https://docs.example.com/minutes)")
    expect(markdown).toContain("# Attendees")
    expect(markdown).toContain("- Alice")
    expect(markdown).toContain("- Bob")
    expect(markdown).toContain("| Topic | Owner |")
    expect(markdown).toContain("| Budget | Alice |")

    expect(markdown).not.toContain("docs-internal-guid")
    expect(markdown).not.toContain("font-weight")
    expect(markdown).not.toContain("white-space")
  })
})

describe("htmlToMarkdown · 网页复制样本", () => {
  it("converts tasks, strikethrough, fenced code, aligned tables and images", () => {
    const markdown = htmlToMarkdown(WEB_COPY_HTML)

    expect(markdown).toContain("## Migration *guide*")
    expect(markdown).toContain(
      "Use **bold**, *italic*, `inline_code()`, ~~legacy flags~~, and a [reference link](https://example.com/docs).",
    )
    expect(markdown).toContain("- [x] done task")
    expect(markdown).toContain("- [ ] open task")
    expect(markdown).toContain("```python")
    expect(markdown).toContain("def migrate():")
    expect(markdown).toContain("| Feature | Status |")
    expect(markdown).toContain("| :-: | --- |")
    expect(markdown).toContain("| Tables | yes |")
    expect(markdown).toContain("![Architecture diagram](https://example.com/diagram.png)")
  })
})

describe("htmlToMarkdown · 回退语义", () => {
  it("returns empty string for blank input", () => {
    expect(htmlToMarkdown("")).toBe("")
    expect(htmlToMarkdown("   \n  ")).toBe("")
  })

  it("returns empty string when nothing convertible remains", () => {
    // 仅样式/元信息，无正文内容 → 产物为空，调用方回退纯文本。
    expect(htmlToMarkdown("<meta charset='utf-8'><style>b{}</style>")).toBe("")
  })

  it("keeps plain text paste content untouched by html-only boilerplate", () => {
    const markdown = htmlToMarkdown(
      "<span dir=ltr>Plain sentence.</span><o:p></o:p>",
    )
    expect(markdown).toBe("Plain sentence.")
  })
})

describe("markdownFromClipboard", () => {
  it("converts when text/html is present and non-empty", () => {
    const clipboard = {
      getData: (type: string) =>
        type === "text/html"
          ? "<p>Hello <strong>world</strong>.</p>"
          : "Hello world.",
    }
    expect(markdownFromClipboard(clipboard)).toBe("Hello **world**.")
  })

  it("falls back to null without text/html", () => {
    const clipboard = {
      getData: (type: string) => (type === "text/plain" ? "plain" : ""),
    }
    expect(markdownFromClipboard(clipboard)).toBeNull()
    expect(markdownFromClipboard(null)).toBeNull()
  })

  it("falls back to null when conversion yields nothing", () => {
    const clipboard = {
      getData: (type: string) => (type === "text/html" ? "<style>a{}</style>" : "x"),
    }
    expect(markdownFromClipboard(clipboard)).toBeNull()
  })
})
