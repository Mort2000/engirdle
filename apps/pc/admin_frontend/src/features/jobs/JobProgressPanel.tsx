import { useEffect, useState } from "react"

import {
  inStagePercent,
  PIPELINE_STAGES,
  unitCounterLabel,
} from "@/lib/progress"
import { formatRelativeTime } from "@/lib/time"
import { cn } from "@/lib/utils"
import type { JobDetailPayload } from "@/api/jobs"
import type { JobStreamState } from "@/api/hooks/useJobStream"
import { Stepper } from "@/components/progress/Stepper"
import { Progress } from "@/components/ui/progress"

const STREAM_LABELS: Record<JobStreamState, string | null> = {
  connecting: "连接中",
  live: "实时",
  degraded: "轮询降级",
  closed: "已结束",
  idle: null,
}

/** 心跳相对时间在任务运行时每秒刷新（R5：直观暴露进度停滞）。 */
function useTick(active: boolean): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    if (!active) {
      return
    }
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [active])
  return now
}

/**
 * 进度面板（设计 §8.4）：Stepper（8 阶段）+ Progress 条（阶段内百分比或
 * indeterminate 动画）+ 实时计数 + 心跳相对时间 + 流状态指示。
 */
export function JobProgressPanel({
  job,
  streamState,
}: {
  job: JobDetailPayload
  streamState: JobStreamState
}) {
  const progress = job.progress
  const inStage = inStagePercent(
    progress.stage,
    progress.done_units,
    progress.total_units,
  )
  const counter = unitCounterLabel(
    progress.stage,
    progress.done_units,
    progress.total_units,
  )
  const now = useTick(job.status === "running")
  const streamLabel = STREAM_LABELS[streamState]

  return (
    <section aria-label="任务进度" className="rounded-xl border bg-card p-6 shadow-sm">
      <Stepper
        stages={PIPELINE_STAGES}
        currentIndex={progress.stage_index}
        className="mb-6"
      />

      {inStage === null ? (
        <div
          data-slot="progress-indeterminate"
          role="progressbar"
          aria-label="阶段进度（不确定）"
          className="relative h-2 w-full overflow-hidden rounded-full bg-primary/20"
        >
          <div className="absolute inset-y-0 left-0 w-1/4 animate-progress-indeterminate rounded-full bg-primary" />
        </div>
      ) : (
        <Progress aria-label="阶段进度" value={inStage} />
      )}

      <div className="mt-3 flex flex-wrap items-center gap-x-6 gap-y-1 text-sm text-muted-foreground">
        <span>
          总进度{" "}
          <span className="font-medium text-foreground">
            {progress.percent.toFixed(1)}%
          </span>
        </span>
        {counter && <span>{counter}</span>}
        <span>
          心跳{" "}
          <span className="font-medium text-foreground">
            {formatRelativeTime(job.heartbeat_at, now)}
          </span>
        </span>
        {streamLabel && (
          <span
            data-stream-state={streamState}
            className={cn(
              "inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-xs",
              streamState === "live" && "bg-blue-500/15 text-blue-600 dark:text-blue-400",
              streamState === "degraded" &&
                "bg-amber-500/15 text-amber-600 dark:text-amber-400",
              (streamState === "connecting" || streamState === "closed") &&
                "bg-secondary text-secondary-foreground",
            )}
          >
            {streamState === "live" && (
              <span
                aria-hidden="true"
                className="size-1.5 animate-pulse rounded-full bg-current"
              />
            )}
            {streamLabel}
          </span>
        )}
      </div>
    </section>
  )
}
