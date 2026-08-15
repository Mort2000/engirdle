import { Link } from "react-router"

import { PagePlaceholder } from "@/components/layout/PagePlaceholder"
import { Button } from "@/components/ui/button"

export function VoicesPage() {
  return (
    <PagePlaceholder
      title="声音配置"
      description="声音配置总览（对应 voices.html，后续阶段接入）。"
      breadcrumbs={[{ label: "工作台", to: "/" }, { label: "声音配置" }]}
      actions={
        <Button asChild>
          <Link to="/voices/new">新建锚点候选</Link>
        </Button>
      }
    />
  )
}
