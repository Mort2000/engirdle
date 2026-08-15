/**
 * 文章修订状态徽标（§6.3 语义色的文章侧对应物）：
 * draft 灰 / structured 蓝 / approved 琥珀 / published 绿。
 * 结构确认页与工作台文章库共用。
 */

import { Badge } from "@/components/ui/badge"
import type { RevisionStatus } from "@/api/articles"
import { cn } from "@/lib/utils"

const STATUS_CONFIG: Record<RevisionStatus, string> = {
  draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  structured: "bg-blue-100 text-blue-700 dark:bg-blue-950 dark:text-blue-300",
  approved: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  published:
    "bg-emerald-100 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300",
}

const STATUS_LABEL: Record<RevisionStatus, string> = {
  draft: "草稿",
  structured: "已解析",
  approved: "已冻结",
  published: "已发布",
}

export function ArticleStatusBadge({
  status,
  className,
}: {
  status: string
  className?: string
}) {
  const label = STATUS_LABEL[status as RevisionStatus] ?? status
  return (
    <Badge className={cn(STATUS_CONFIG[status as RevisionStatus] ?? "", className)}>
      {label}
    </Badge>
  )
}
