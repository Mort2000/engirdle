/**
 * 新修订录入页（设计 §5.1 /articles/:id/new-revision）：预填当前最新
 * 修订（含 raw_text 原始 Markdown），提交 POST /api/articles/{id}/revisions
 * 创建不可变新修订，成功后跳转其结构确认页。
 */

import { useParams } from "react-router"

import { useLatestArticle, useCreateArticleRevisionMutation } from "@/api/hooks/articles"
import { PageHeader } from "@/components/layout/PageHeader"
import { Skeleton } from "@/components/ui/skeleton"
import { ArticleEntryForm } from "@/features/articles/ArticleEntryForm"

export function ArticleRevisionNewPage() {
  const { articleId } = useParams()
  const latest = useLatestArticle(articleId)
  const createRevision = useCreateArticleRevisionMutation(articleId)

  return (
    <div className="space-y-6">
      <PageHeader
        title={latest.data ? `修改 ${latest.data.title}` : "创建新修订"}
        breadcrumbs={[
          { label: "工作台", to: "/" },
          { label: "文章" },
          { label: articleId ?? "…" },
          { label: "新修订" },
        ]}
      />

      {latest.isPending ? (
        <div className="space-y-4" aria-busy="true" aria-label="正在载入最新修订">
          <Skeleton className="h-10 w-full" />
          <Skeleton className="h-96 w-full" />
        </div>
      ) : latest.isError || !latest.data ? (
        <div
          role="alert"
          className="rounded-lg border border-destructive/50 bg-destructive/10 p-4 text-sm text-destructive"
        >
          无法载入文章 {articleId} 的最新修订：
          {latest.error instanceof Error ? latest.error.message : "未知错误"}
        </div>
      ) : (
        <>
          <p className="max-w-3xl text-sm leading-relaxed text-muted-foreground">
            当前修订 {latest.data.revision} 保持不可变；保存后创建修订{" "}
            {latest.data.revision + 1}。原始输入会原样带入编辑器，修改后重新
            冻结结构。
          </p>
          <section className="rounded-xl border bg-card p-6">
            <ArticleEntryForm
              defaults={{
                title: latest.data.title,
                body: latest.data.raw_text,
                author: latest.data.source.author ?? "",
                source_name: latest.data.source.display_name ?? "",
                source_url: latest.data.source.url ?? "",
                license_name: latest.data.source.license_name,
              }}
              submitLabel="创建新修订"
              onSubmitInput={(input) => createRevision.mutateAsync(input)}
              cancelTo={`/articles/${articleId}/revisions/${latest.data.revision}`}
            />
          </section>
        </>
      )}
    </div>
  )
}
