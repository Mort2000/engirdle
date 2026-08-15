import { Link } from "react-router"

import { PageHeader } from "@/components/layout/PageHeader"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"

/**
 * 前端路由深链 fallback（设计 §5.1）：服务端对未知 GET 统一返回
 * index.html 后由该页兜底，保持在 AppShell 布局内。
 */
export function NotFoundPage() {
  return (
    <div className="flex flex-col gap-6">
      <PageHeader
        title="页面不存在"
        breadcrumbs={[{ label: "工作台", to: "/" }, { label: "未找到" }]}
      />
      <Card>
        <CardContent className="flex flex-col gap-4 pt-6">
          <p className="text-sm text-muted-foreground">
            没有匹配的路由：链接可能已过期。回到工作台继续操作。
          </p>
          <Button asChild className="w-fit">
            <Link to="/">返回工作台</Link>
          </Button>
        </CardContent>
      </Card>
    </div>
  )
}
