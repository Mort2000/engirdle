import type { ReactNode } from "react"

import {
  PageHeader,
  type BreadcrumbItem,
} from "@/components/layout/PageHeader"
import { Card, CardContent } from "@/components/ui/card"

interface PagePlaceholderProps {
  title: string
  description: string
  breadcrumbs: BreadcrumbItem[]
  /** 右上主操作区（设计 §6.1）：功能页接入前可先挂真实导航或留空。 */
  actions?: ReactNode
}

/**
 * 功能页占位骨架（设计 §12 步骤 3）：
 * 页头（面包屑 + 标题 + 主操作区）+ 卡片式说明面板。
 * 各功能页在步骤 4 逐页替换为真实实现。
 */
export function PagePlaceholder({
  title,
  description,
  breadcrumbs,
  actions,
}: PagePlaceholderProps) {
  return (
    <div className="flex flex-col gap-6">
      <PageHeader title={title} breadcrumbs={breadcrumbs} actions={actions} />
      <Card>
        <CardContent className="flex flex-col gap-4 pt-6">
          <p className="text-sm text-muted-foreground">{description}</p>
          <div
            aria-hidden="true"
            className="h-1.5 w-24 rounded-full bg-primary/30"
          />
        </CardContent>
      </Card>
    </div>
  )
}
