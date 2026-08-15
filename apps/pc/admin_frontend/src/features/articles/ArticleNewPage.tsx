/**
 * 文章录入页（设计 §5.1 /articles/new）：Markdown 编辑器录入新文章，
 * 提交 POST /api/articles 后跳转结构确认页（§12 步骤 4）。
 */

import { useCreateArticleMutation } from "@/api/hooks/articles"
import { PageHeader } from "@/components/layout/PageHeader"
import { ArticleEntryForm } from "@/features/articles/ArticleEntryForm"

const GFM_NOTICE =
  "支持 GFM 子集：标题、段落、列表、引用、强调、链接、行内代码、表格、代码块与分隔线。代码块内容只在本地处理，永不发送给 LLM 或 TTS。粘贴富文本（网页 / Word / Google Docs）会自动转换为 Markdown。"

export function ArticleNewPage() {
  const createArticle = useCreateArticleMutation()

  return (
    <div className="space-y-6">
      <PageHeader
        title="录入文章"
        breadcrumbs={[{ label: "工作台", to: "/" }, { label: "文章" }, { label: "录入" }]}
      />
      <p className="max-w-3xl text-sm leading-relaxed text-muted-foreground">
        {GFM_NOTICE}
      </p>
      <section className="rounded-xl border bg-card p-6">
        <ArticleEntryForm
          defaults={{
            title: "",
            body: "",
            author: "",
            source_name: "",
            source_url: "",
            license_name: "unknown",
          }}
          submitLabel="保存并生成候选结构"
          onSubmitInput={(input) => createArticle.mutateAsync(input)}
          cancelTo="/"
        />
      </section>
    </div>
  )
}
