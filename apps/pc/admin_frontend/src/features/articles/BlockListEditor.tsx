/**
 * 结构化块编辑器（设计 §7.3 / §12 步骤 4）：彻底替换整页 JSON textarea。
 *
 * - 块级：上移/下移重排、同类文本块“与上一块合并”（句子列表拼接）；
 * - 句级：textarea 编辑、拆分（优先光标位置，其次最后一个句末标点，
 *   再次词边界中点）、合并到上一句；
 * - 表格：单元格（含表头）文本编辑 + 每列对齐方式；
 * - 保存前经 zod schema（editedBlockSchema，与后端 EditedBlockRequest
 *   同构）整体校验，失败在页内以红 Alert 呈现，不发起请求。
 */

import { useMemo, useRef, useState } from "react"
import { toast } from "sonner"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import { Textarea } from "@/components/ui/textarea"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import {
  editStructureSchema,
  type EditedBlockPayload,
  type EditStructurePayload,
  type TextEditedBlockPayload,
} from "@/features/articles/editedBlockSchema"
import {
  canMergeIntoPrevious,
  isTextBlock,
  splitSentenceAt,
} from "@/features/articles/blockOps"

const KIND_LABELS: Record<EditedBlockPayload["kind"], string> = {
  paragraph: "段落",
  heading: "标题",
  list_item: "列表项",
  quote: "引用",
  table: "表格",
  code: "代码块",
  divider: "分隔线",
}

const ALIGNMENT_LABELS: Record<string, string> = {
  default: "默认",
  left: "左对齐",
  center: "居中",
  right: "右对齐",
}

function kindDetail(block: EditedBlockPayload): string {
  switch (block.kind) {
    case "heading":
      return `H${block.level}`
    case "list_item":
      return `${block.list_kind === "ordered" ? "有序" : "无序"} · 深度 ${block.list_depth}`
    case "quote":
      return `深度 ${block.quote_depth}`
    default:
      return ""
  }
}

export interface BlockListEditorProps {
  /** 初始载荷（blocksFromRevisionPayload 派生）。 */
  blocks: EditedBlockPayload[]
  /** 保存动作（页面执行 PUT structure）；reject 表示后端拒绝。 */
  onSave: (payload: EditStructurePayload) => Promise<void>
  saving: boolean
}

export function BlockListEditor({
  blocks,
  onSave,
  saving,
}: BlockListEditorProps) {
  const [items, setItems] = useState<EditedBlockPayload[]>(blocks)
  const [baseline, setBaseline] = useState<EditedBlockPayload[]>(blocks)
  const [validationIssues, setValidationIssues] = useState<string[] | null>(null)
  const cursors = useRef(new Map<string, number>())

  const dirty = useMemo(
    () => JSON.stringify(items) !== JSON.stringify(baseline),
    [items, baseline],
  )

  const updateItem = (index: number, updated: EditedBlockPayload) => {
    setItems((current) =>
      current.map((item, position) => (position === index ? updated : item)),
    )
  }

  const moveItem = (index: number, offset: -1 | 1) => {
    setItems((current) => {
      const target = index + offset
      if (target < 0 || target >= current.length) {
        return current
      }
      const next = [...current]
      const [moved] = next.splice(index, 1)
      next.splice(target, 0, moved as EditedBlockPayload)
      return next
    })
  }

  const mergeBlockIntoPrevious = (index: number) => {
    setItems((current) => {
      const previous = current[index - 1]
      const currentBlock = current[index]
      if (!previous || !currentBlock) {
        return current
      }
      if (!isTextBlock(previous) || !isTextBlock(currentBlock)) {
        return current
      }
      const merged: TextEditedBlockPayload = {
        ...previous,
        sentences: [...previous.sentences, ...currentBlock.sentences],
      }
      const next = [...current]
      next.splice(index - 1, 2, merged)
      return next
    })
  }

  const updateSentences = (
    index: number,
    sentences: TextEditedBlockPayload["sentences"],
  ) => {
    setItems((current) =>
      current.map((item, position) =>
        position === index && isTextBlock(item) ? { ...item, sentences } : item,
      ),
    )
  }

  const splitSentence = (index: number, sentenceIndex: number) => {
    const block = items[index]
    if (!block || !isTextBlock(block)) {
      return
    }
    const sentence = block.sentences[sentenceIndex]
    if (!sentence) {
      return
    }
    const cursor = cursors.current.get(`${index}:${sentenceIndex}`) ?? null
    const split = splitSentenceAt(sentence.text, cursor)
    if (!split) {
      toast.error("无法在此处拆分：需要能得到两个非空半句")
      return
    }
    const sentences = [...block.sentences]
    sentences.splice(
      sentenceIndex,
      1,
      { sentence_id: sentence.sentence_id, text: split.first },
      { sentence_id: null, text: split.second },
    )
    updateSentences(index, sentences)
  }

  const mergeSentenceIntoPrevious = (index: number, sentenceIndex: number) => {
    const block = items[index]
    if (!block || !isTextBlock(block) || sentenceIndex === 0) {
      return
    }
    const previous = block.sentences[sentenceIndex - 1]
    const current = block.sentences[sentenceIndex]
    if (!previous || !current) {
      return
    }
    const sentences = [...block.sentences]
    sentences.splice(
      sentenceIndex - 1,
      2,
      {
        sentence_id: previous.sentence_id,
        text: `${previous.text} ${current.text}`.trim(),
      },
    )
    updateSentences(index, sentences)
  }

  const save = async () => {
    const parsed = editStructureSchema.safeParse({ blocks: items })
    if (!parsed.success) {
      setValidationIssues(
        parsed.error.issues.map(
          (issue) =>
            `块 ${String(issue.path[0] ?? 0)}：${issue.path.slice(1).join(" / ") || "载荷"} — ${issue.message}`,
        ),
      )
      return
    }
    setValidationIssues(null)
    try {
      await onSave(parsed.data)
      setBaseline(items)
    } catch {
      // 错误提示（Toast/Alert）由页面侧处理。
    }
  }

  return (
    <section className="space-y-4" aria-label="结构编辑器">
      <div className="flex items-center justify-between">
        <h2 className="text-base font-semibold">结构化编辑器</h2>
        <div className="flex items-center gap-3">
          {dirty && (
            <span className="text-xs text-amber-600 dark:text-amber-400">
              有未保存的修改
            </span>
          )}
          <Button onClick={save} disabled={saving || !dirty}>
            {saving ? "保存中…" : "保存结构"}
          </Button>
        </div>
      </div>
      <p className="text-sm text-muted-foreground">
        调整块顺序、编辑句子、拆分或合并句子与同类块、编辑表格单元格。ID
        留空的新句子保存后由服务端自动分配。
      </p>

      {validationIssues && (
        <Alert variant="destructive">
          <AlertTitle>结构校验未通过</AlertTitle>
          <AlertDescription>
            {validationIssues.slice(0, 5).map((issue) => (
              <p key={issue}>{issue}</p>
            ))}
          </AlertDescription>
        </Alert>
      )}

      <ol className="space-y-4">
        {items.map((block, index) => (
          <li
            key={block.block_id ?? `new-${index}`}
            className="rounded-xl border bg-card p-4"
          >
            <div className="mb-3 flex flex-wrap items-center gap-2">
              <span className="text-xs tabular-nums text-muted-foreground">
                #{index + 1}
              </span>
              <Badge variant="secondary">{KIND_LABELS[block.kind]}</Badge>
              {kindDetail(block) && (
                <span className="text-xs text-muted-foreground">
                  {kindDetail(block)}
                </span>
              )}
              <code className="max-w-40 truncate font-mono text-[11px] text-muted-foreground">
                {block.block_id ?? "（新块）"}
              </code>
              <div className="ml-auto flex items-center gap-1">
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => moveItem(index, -1)}
                  disabled={index === 0}
                  aria-label={`上移块 ${index + 1}`}
                >
                  上移
                </Button>
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => moveItem(index, 1)}
                  disabled={index === items.length - 1}
                  aria-label={`下移块 ${index + 1}`}
                >
                  下移
                </Button>
                {index > 0 && canMergeIntoPrevious(items[index - 1]!, block) && (
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => mergeBlockIntoPrevious(index)}
                    aria-label={`合并块 ${index + 1} 到上一块`}
                  >
                    与上一块合并
                  </Button>
                )}
              </div>
            </div>

            {isTextBlock(block) && (
              <div className="space-y-2">
                {block.sentences.map((sentence, sentenceIndex) => (
                  <div key={sentence.sentence_id ?? `new-${sentenceIndex}`}>
                    <Textarea
                      value={sentence.text}
                      aria-label={`句子 ${index + 1}-${sentenceIndex + 1}`}
                      rows={2}
                      onChange={(event) => {
                        const sentences = [...block.sentences]
                        sentences[sentenceIndex] = {
                          sentence_id: sentence.sentence_id,
                          text: event.target.value,
                        }
                        updateSentences(index, sentences)
                      }}
                      onSelect={(event) =>
                        cursors.current.set(
                          `${index}:${sentenceIndex}`,
                          event.currentTarget.selectionStart ?? 0,
                        )
                      }
                      onClick={(event) =>
                        cursors.current.set(
                          `${index}:${sentenceIndex}`,
                          event.currentTarget.selectionStart ?? 0,
                        )
                      }
                    />
                    <div className="mt-1 flex justify-end gap-2">
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => splitSentence(index, sentenceIndex)}
                        aria-label={`拆分句子 ${index + 1}-${sentenceIndex + 1}`}
                        title="将光标放在拆分点后点击；无光标时按句末标点或词边界拆分"
                      >
                        拆分
                      </Button>
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() =>
                          mergeSentenceIntoPrevious(index, sentenceIndex)
                        }
                        disabled={sentenceIndex === 0}
                        aria-label={`合并句子 ${index + 1}-${sentenceIndex + 1} 到上一句`}
                      >
                        合并到上一句
                      </Button>
                    </div>
                  </div>
                ))}
              </div>
            )}

            {block.kind === "table" && (
              <div className="space-y-3 overflow-x-auto">
                <div className="grid gap-2" style={{ gridTemplateColumns: `repeat(${block.header.length}, minmax(10rem, 1fr))` }}>
                  {block.header.map((cell, columnIndex) => (
                    <Input
                      key={`header-${columnIndex}`}
                      value={cell}
                      aria-label={`块 ${index + 1} 表头列 ${columnIndex + 1}`}
                      onChange={(event) => {
                        const header = [...block.header]
                        header[columnIndex] = event.target.value
                        updateItem(index, { ...block, header })
                      }}
                    />
                  ))}
                </div>
                <div className="flex flex-wrap items-center gap-2">
                  {block.alignments.map((alignment, columnIndex) => (
                    <Select
                      key={`alignment-${columnIndex}`}
                      value={alignment}
                      onValueChange={(value) => {
                        const alignments = [...block.alignments]
                        alignments[columnIndex] = value as typeof alignment
                        updateItem(index, { ...block, alignments })
                      }}
                    >
                      <SelectTrigger
                        className="h-8 w-28"
                        aria-label={`块 ${index + 1} 列 ${columnIndex + 1} 对齐`}
                      >
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        {Object.entries(ALIGNMENT_LABELS).map(
                          ([value, label]) => (
                            <SelectItem key={value} value={value}>
                              {label}
                            </SelectItem>
                          ),
                        )}
                      </SelectContent>
                    </Select>
                  ))}
                </div>
                {block.rows.map((row, rowIndex) => (
                  <div
                    key={`row-${rowIndex}`}
                    className="grid gap-2"
                    style={{ gridTemplateColumns: `repeat(${row.length}, minmax(10rem, 1fr))` }}
                  >
                    {row.map((cell, columnIndex) => (
                      <Input
                        key={`cell-${rowIndex}-${columnIndex}`}
                        value={cell}
                        aria-label={`块 ${index + 1} 行 ${rowIndex + 1} 列 ${columnIndex + 1}`}
                        onChange={(event) => {
                          const rows = block.rows.map((currentRow) => [
                            ...currentRow,
                          ])
                          rows[rowIndex]![columnIndex] = event.target.value
                          updateItem(index, { ...block, rows })
                        }}
                      />
                    ))}
                  </div>
                ))}
              </div>
            )}

            {block.kind === "code" && (
              <div className="space-y-2">
                <Input
                  value={block.language ?? ""}
                  placeholder="语言（可选）"
                  aria-label={`块 ${index + 1} 语言`}
                  onChange={(event) =>
                    updateItem(index, {
                      ...block,
                      language: event.target.value.trim() || null,
                    })
                  }
                />
                <Textarea
                  value={block.code}
                  rows={5}
                  spellCheck={false}
                  className="font-mono text-[13px]"
                  aria-label={`块 ${index + 1} 代码`}
                  onChange={(event) =>
                    updateItem(index, { ...block, code: event.target.value })
                  }
                />
              </div>
            )}

            {block.kind === "divider" && (
              <p className="text-sm text-muted-foreground">——— 分隔线 ———</p>
            )}
          </li>
        ))}
      </ol>
    </section>
  )
}
