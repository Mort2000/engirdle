/**
 * 译文审阅面板（设计 §8.4）：
 * - 句级三列：原文 / 机翻 / 修正（可保存，PUT translations/{sentence_id}）；
 * - 表格 cell 级编辑：整表一次请求（PUT table-translations/{block_id}）。
 *
 * 保存入口仅在 review_required 状态开放（后端 require_review 同语义），
 * 其余状态只读展示机翻结果。
 */

import { useState } from "react"
import { toast } from "sonner"

import {
  useEditSentenceTranslationMutation,
  useEditTableTranslationMutation,
} from "@/api/hooks/jobs"
import type {
  SentenceTranslationPayload,
  TableTranslationPayload,
} from "@/api/jobs"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { Textarea } from "@/components/ui/textarea"

function mutationError(error: unknown): string {
  return error instanceof Error ? error.message : "保存失败"
}

function SentenceReviewRow({
  jobId,
  entry,
  editable,
}: {
  jobId: string
  entry: SentenceTranslationPayload
  editable: boolean
}) {
  const [draft, setDraft] = useState(entry.published_text)
  const mutation = useEditSentenceTranslationMutation(jobId)
  const saving = mutation.isPending && mutation.variables?.sentenceId === entry.sentence_id

  return (
    <div className="grid gap-2 md:grid-cols-3" data-sentence-id={entry.sentence_id}>
      <p className="self-start text-sm leading-relaxed text-muted-foreground">
        {entry.source_text || "（无原文）"}
      </p>
      <p className="self-start text-sm leading-relaxed text-muted-foreground/80 italic">
        {entry.generated_text}
      </p>
      <div className="flex items-start gap-2">
        <Textarea
          aria-label={`修正译文 ${entry.sentence_id}`}
          rows={2}
          value={draft}
          readOnly={!editable}
          onChange={(event) => setDraft(event.target.value)}
          className="min-w-0 flex-1"
        />
        <Button
          type="button"
          variant="secondary"
          size="sm"
          className="shrink-0 self-end"
          disabled={!editable || saving || draft.trim() === "" || draft === entry.published_text}
          onClick={() =>
            mutation.mutate(
              { sentenceId: entry.sentence_id, textZh: draft.trim() },
              {
                onSuccess: () => toast.success("已保存句级修正"),
                onError: (error) => toast.error(mutationError(error)),
              },
            )
          }
        >
          {saving ? "保存中…" : "保存修正"}
        </Button>
      </div>
    </div>
  )
}

function TableReviewBlock({
  jobId,
  table,
  editable,
}: {
  jobId: string
  table: TableTranslationPayload
  editable: boolean
}) {
  const [drafts, setDrafts] = useState<Record<string, string>>(() =>
    Object.fromEntries(table.cells.map((cell) => [cell.cell_id, cell.published_text])),
  )
  const mutation = useEditTableTranslationMutation(jobId)
  const saving = mutation.isPending && mutation.variables?.blockId === table.unit_id

  return (
    <div className="space-y-3" data-table-id={table.unit_id}>
      <h3 className="font-mono text-xs text-muted-foreground">{table.unit_id}</h3>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {table.cells.map((cell) => (
          <label key={cell.cell_id} className="space-y-1">
            <span className="font-mono text-[11px] text-muted-foreground">
              {cell.cell_id}
            </span>
            <Textarea
              aria-label={`表格单元格 ${cell.cell_id}`}
              rows={1}
              value={drafts[cell.cell_id] ?? ""}
              readOnly={!editable}
              onChange={(event) =>
                setDrafts((previous) => ({
                  ...previous,
                  [cell.cell_id]: event.target.value,
                }))
              }
            />
          </label>
        ))}
      </div>
      <Button
        type="button"
        variant="secondary"
        size="sm"
        disabled={!editable || saving}
        onClick={() =>
          mutation.mutate(
            {
              blockId: table.unit_id,
              cells: table.cells.map((cell) => ({
                cell_id: cell.cell_id,
                text_zh: (drafts[cell.cell_id] ?? "").trim(),
              })),
            },
            {
              onSuccess: () => toast.success("已保存整表修正"),
              onError: (error) => toast.error(mutationError(error)),
            },
          )
        }
      >
        {saving ? "保存中…" : "保存整表修正"}
      </Button>
    </div>
  )
}

export function TranslationReviewPanel({
  jobId,
  sentences,
  tables,
  editable,
  loading,
}: {
  jobId: string
  sentences: SentenceTranslationPayload[]
  tables: TableTranslationPayload[]
  editable: boolean
  loading: boolean
}) {
  if (loading && sentences.length === 0 && tables.length === 0) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>译文审阅</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2">
          <Skeleton className="h-12 w-full" />
          <Skeleton className="h-12 w-full" />
        </CardContent>
      </Card>
    )
  }
  if (sentences.length === 0 && tables.length === 0) {
    return null
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>译文审阅</CardTitle>
        <CardDescription>
          原文 / 机翻 / 修正三列对照
          {editable ? "；保存后立即生效于发布产物。" : "；当前状态只读，进入人工审阅后可保存修正。"}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-6">
        {sentences.length > 0 && (
          <div className="space-y-4">
            <div className="hidden grid-cols-3 gap-2 text-xs font-medium text-muted-foreground md:grid">
              <span>原文</span>
              <span>机翻</span>
              <span>修正</span>
            </div>
            {sentences.map((entry) => (
              <SentenceReviewRow
                key={entry.sentence_id}
                jobId={jobId}
                entry={entry}
                editable={editable}
              />
            ))}
          </div>
        )}
        {tables.length > 0 && (
          <div className="space-y-6 border-t pt-6">
            <div className="space-y-1">
              <h3 className="text-sm font-semibold">表格译文审阅</h3>
              <p className="text-xs text-muted-foreground">
                每张表一次请求生成；人工修正按 cell 编辑，保存时校验行列与 cell ID 不变。
              </p>
            </div>
            {tables.map((table) => (
              <TableReviewBlock
                key={table.unit_id}
                jobId={jobId}
                table={table}
                editable={editable}
              />
            ))}
          </div>
        )}
      </CardContent>
    </Card>
  )
}
