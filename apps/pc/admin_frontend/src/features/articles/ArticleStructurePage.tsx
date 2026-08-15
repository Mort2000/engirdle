import { useParams } from "react-router"

import { PagePlaceholder } from "@/components/layout/PagePlaceholder"

export function ArticleStructurePage() {
  const { articleId, revision } = useParams()

  return (
    <PagePlaceholder
      title="结构确认"
      description="结构树、解析警告与结构化编辑器（对应 article_structure.html，后续阶段接入）。"
      breadcrumbs={[
        { label: "工作台", to: "/" },
        { label: "文章" },
        { label: articleId ?? "…" },
        { label: `修订 ${revision ?? "…"}` },
      ]}
    />
  )
}
