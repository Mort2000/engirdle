import { Link } from "react-router"

import { PagePlaceholder } from "@/components/layout/PagePlaceholder"
import { Button } from "@/components/ui/button"

export function DashboardPage() {
  return (
    <PagePlaceholder
      title="工作台"
      description="文章 / 任务 / 发布概览与发布器面板（对应 dashboard.html，后续阶段接入）。"
      breadcrumbs={[{ label: "工作台" }]}
      actions={
        <Button asChild>
          <Link to="/articles/new">录入文章</Link>
        </Button>
      }
    />
  )
}
