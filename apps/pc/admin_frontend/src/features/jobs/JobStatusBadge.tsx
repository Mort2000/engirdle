import { cn } from "@/lib/utils"
import type { JobStatus } from "@/api/jobs"
import { Badge } from "@/components/ui/badge"

const STATUS_CONFIG: Record<JobStatus, { label: string; className: string; pulse?: boolean }> = {
  queued: {
    label: "排队中",
    className: "bg-zinc-500/15 text-zinc-600 dark:text-zinc-300",
  },
  running: {
    label: "运行中",
    className: "bg-blue-500/15 text-blue-600 dark:text-blue-400",
    pulse: true,
  },
  review_required: {
    label: "待人工审阅",
    className: "bg-amber-500/15 text-amber-600 dark:text-amber-400",
  },
  failed: {
    label: "失败",
    className: "bg-red-500/15 text-red-600 dark:text-red-400",
  },
  succeeded: {
    label: "已成功",
    className: "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400",
  },
}

/**
 * 任务状态徽标（§6.3 语义色）：queued 灰 / running 蓝（脉动点）/
 * review_required 琥珀 / failed 红 / succeeded 绿。
 */
export function JobStatusBadge({
  status,
  className,
}: {
  status: JobStatus
  className?: string
}) {
  const config = STATUS_CONFIG[status] ?? STATUS_CONFIG.queued
  return (
    <Badge className={cn("gap-1.5", config.className, className)}>
      {config.pulse && (
        <span
          aria-hidden="true"
          className="size-1.5 animate-pulse rounded-full bg-current"
        />
      )}
      {config.label}
    </Badge>
  )
}
