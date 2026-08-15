import { useParams } from "react-router"

import { PagePlaceholder } from "@/components/layout/PagePlaceholder"

export function ArticleRevisionNewPage() {
  const { articleId } = useParams()

  return (
    <PagePlaceholder
      title="新修订录入"
      description="基于既有文章的原始输入创建新修订（对应 article_revision_new.html，后续阶段接入）。"
      breadcrumbs={[
        { label: "工作台", to: "/" },
        { label: "文章" },
        { label: articleId ?? "…" },
        { label: "新修订" },
      ]}
    />
  )
}
