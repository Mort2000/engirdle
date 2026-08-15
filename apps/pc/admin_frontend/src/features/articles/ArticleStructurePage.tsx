/**
 * 结构确认页（设计 §5.1 /articles/:id/revisions/:rev，§7.3 / §11）：
 * - 解析警告（琥珀 Alert，§6.3）+ 处理计数（structure-report 端点）；
 * - 结构树（派生 translates/narrates，只读，不可手工切换）；
 * - 结构化编辑器（BlockListEditor，替换整页 JSON textarea），保存走
 *   既有 PUT .../structure；
 * - draft/structured 可编辑并冻结（approve → 跳转任务页）；已冻结修订
 *   提供重建与新修订入口；删除文章走 AlertDialog 且要求输入文章 ID。
 */

import { useMemo } from "react"
import { Link, useNavigate, useParams } from "react-router"
import { toast } from "sonner"

import {
  useApproveRevisionMutation,
  useArticle,
  useEditStructureMutation,
  useRebuildRevisionMutation,
} from "@/api/hooks/articles"
import { useStructureReport } from "@/api/hooks/jobs"
import type { EditStructurePayload } from "@/features/articles/editedBlockSchema"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { PageHeader } from "@/components/layout/PageHeader"
import {
  BlockListEditor,
} from "@/features/articles/BlockListEditor"
import { DeleteArticleDialog } from "@/features/articles/DeleteArticleDialog"
import { ArticleStatusBadge } from "@/features/articles/ArticleStatusBadge"
import { blocksFromRevisionPayload } from "@/features/articles/editedBlockSchema"

function StructureTreeSkeleton() {
  return (
    <div className="space-y-2" aria-busy="true" aria-label="结构树加载中">
      {Array.from({ length: 4 }, (_, index) => (
        <Skeleton key={index} className="h-9 w-full" />
      ))}
    </div>
  )
}

export function ArticleStructurePage() {
  const { articleId, revision: revisionParam } = useParams()
  const navigate = useNavigate()
  const revision = Number.parseInt(revisionParam ?? "", 10)
  const validRevision = Number.isFinite(revision) ? revision : undefined

  const articleQuery = useArticle(articleId, validRevision)
  const reportQuery = useStructureReport(articleId, validRevision)
  const editMutation = useEditStructureMutation(
    articleId ?? "",
    validRevision ?? -1,
  )
  const approveMutation = useApproveRevisionMutation(
    articleId ?? "",
    validRevision ?? -1,
  )
  const rebuildMutation = useRebuildRevisionMutation(
    articleId ?? "",
    validRevision ?? -1,
  )

  const article = articleQuery.data
  const report = reportQuery.data
  const editable =
    article !== undefined &&
    (article.status === "draft" || article.status === "structured")

  const initialBlocks = useMemo(
    () => (article ? blocksFromRevisionPayload(article) : []),
    // 仅在修订载荷变化时重算（保存成功后失效重拉得到新基线）。
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [article?.structure_sha256, article?.revision],
  )

  const onSave = async (payload: EditStructurePayload) => {
    try {
      await editMutation.mutateAsync(payload)
      toast.success("结构已保存")
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "结构保存失败，请重试",
      )
      throw error
    }
  }

  const onApprove = async () => {
    try {
      const job = await approveMutation.mutateAsync()
      toast.success(`已创建任务 ${job.job_id.slice(0, 8)}`)
      navigate(`/jobs/${job.job_id}`)
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "创建任务失败，请重试",
      )
    }
  }

  const onRebuild = async () => {
    try {
      const job = await rebuildMutation.mutateAsync()
      toast.success(`已创建重建任务 ${job.job_id.slice(0, 8)}`)
      navigate(`/jobs/${job.job_id}`)
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "创建重建任务失败，请重试",
      )
    }
  }

  return (
    <div className="space-y-6">
      <PageHeader
        title={article ? article.title : "结构确认"}
        breadcrumbs={[
          { label: "工作台", to: "/" },
          { label: "文章" },
          { label: articleId ?? "…" },
          { label: `修订 ${revisionParam ?? "…"}` },
        ]}
        actions={
          article ? (
            <div className="flex items-center gap-2">
              <ArticleStatusBadge status={article.status} />
              <span className="text-sm text-muted-foreground">
                修订 {article.revision} · {article.blocks.length} 个块
              </span>
            </div>
          ) : undefined
        }
      />

      {report && (
        <p className="text-sm text-muted-foreground">
          {report.processing_counts.translated_sentences} 句待翻译 ·{" "}
          {report.processing_counts.translated_tables} 表待翻译 ·{" "}
          {report.processing_counts.skipped_code_blocks} 个代码块跳过 ·{" "}
          {report.processing_counts.narrated_sentences} 句待朗读
        </p>
      )}

      {reportQuery.data && reportQuery.data.warnings.length > 0 && (
        <Alert variant="warning">
          <AlertTitle>解析警告</AlertTitle>
          <AlertDescription>
            {reportQuery.data.warnings.map((warning) => (
              <p key={warning.code}>
                ⚠ {warning.code} — {warning.message}
              </p>
            ))}
            <p className="text-xs opacity-80">
              存在警告时请先核对结构再冻结；未闭合代码围栏可能吞掉后续正文。
            </p>
          </AlertDescription>
        </Alert>
      )}

      <section className="rounded-xl border bg-card">
        <div className="border-b p-4">
          <h2 className="text-base font-semibold">结构树（处理资格为派生只读结果）</h2>
          <p className="mt-1 text-xs text-muted-foreground">
            表格整表一次翻译且不朗读；代码块与分隔线不翻译、不朗读。这些结果
            由块类型推导，不可手工切换。
          </p>
        </div>
        {reportQuery.isPending ? (
          <div className="p-4">
            <StructureTreeSkeleton />
          </div>
        ) : report ? (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-10">#</TableHead>
                <TableHead>块</TableHead>
                <TableHead>类型</TableHead>
                <TableHead>摘要</TableHead>
                <TableHead className="w-16">翻译</TableHead>
                <TableHead className="w-16">朗读</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {report.structure_tree.map((node, index) => (
                <TableRow key={node.block_id}>
                  <TableCell className="tabular-nums text-muted-foreground">
                    {index}
                  </TableCell>
                  <TableCell className="font-mono text-[12px]">
                    {node.block_id}
                  </TableCell>
                  <TableCell>
                    {node.kind}
                    {node.detail ? `（${node.detail}）` : ""}
                  </TableCell>
                  <TableCell className="max-w-80 truncate text-muted-foreground">
                    {node.summary}
                  </TableCell>
                  <TableCell>{node.translates ? "是" : "否"}</TableCell>
                  <TableCell>{node.narrates ? "是" : "否"}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        ) : (
          <div role="alert" className="p-4 text-sm text-destructive">
            结构报告加载失败：
            {reportQuery.error instanceof Error
              ? reportQuery.error.message
              : "未知错误"}
          </div>
        )}
      </section>

      {articleQuery.isPending ? (
        <Skeleton className="h-64 w-full" />
      ) : articleQuery.isError || !article ? (
        <div
          role="alert"
          className="rounded-lg border border-destructive/50 bg-destructive/10 p-4 text-sm text-destructive"
        >
          修订加载失败：
          {articleQuery.error instanceof Error
            ? articleQuery.error.message
            : "未知错误"}
        </div>
      ) : editable ? (
        <>
          <BlockListEditor
            blocks={initialBlocks}
            onSave={onSave}
            saving={editMutation.isPending}
          />
          <section className="flex flex-col gap-3 rounded-xl border bg-card p-6 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <p className="font-medium">冻结此修订</p>
              <p className="text-sm text-muted-foreground">
                确认后正文和句界不可原地修改，并创建后台生产任务。
              </p>
            </div>
            <Button onClick={onApprove} disabled={approveMutation.isPending}>
              {approveMutation.isPending ? "创建中…" : "确认结构并创建任务"}
            </Button>
          </section>
        </>
      ) : (
        <>
          <section className="rounded-xl border bg-card p-6">
            <h2 className="text-base font-semibold">此修订已冻结</h2>
            <p className="mt-1 text-sm text-muted-foreground">
              可保持正文不变重新生成制品，或基于原始输入创建新修订。
            </p>
            <div className="mt-4 flex flex-wrap gap-3">
              <Button asChild variant="outline">
                <Link to={`/articles/${article.article_id}/new-revision`}>
                  创建新修订
                </Link>
              </Button>
              <Button
                onClick={onRebuild}
                variant="outline"
                disabled={rebuildMutation.isPending}
              >
                {rebuildMutation.isPending ? "创建中…" : "重建此修订"}
              </Button>
            </div>
          </section>
          <section className="rounded-xl border border-destructive/40 bg-card p-6">
            <h2 className="text-base font-semibold text-destructive">
              删除本地文章
            </h2>
            <p className="mt-1 text-sm text-muted-foreground">
              已下载到移动端的内容不受影响。源文件、工作文件和制品将移入可
              恢复 trash。
            </p>
            <DeleteArticleDialog
              articleId={article.article_id}
              onDeleted={() => navigate("/")}
              triggerClassName="mt-4"
            />
          </section>
        </>
      )}
    </div>
  )
}
