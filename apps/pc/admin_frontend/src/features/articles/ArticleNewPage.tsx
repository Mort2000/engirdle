import { PagePlaceholder } from "@/components/layout/PagePlaceholder"

export function ArticleNewPage() {
  return (
    <PagePlaceholder
      title="文章录入"
      description="Markdown 编辑器与富文本粘贴转换（对应 article_new.html，后续阶段接入）。"
      breadcrumbs={[{ label: "工作台", to: "/" }, { label: "文章" }, { label: "录入" }]}
    />
  )
}
