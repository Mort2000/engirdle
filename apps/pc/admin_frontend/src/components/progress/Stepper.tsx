import { Check } from "lucide-react"

import { cn } from "@/lib/utils"
import { stepperStates, type PipelineStage } from "@/lib/progress"

interface StepperProps {
  /** 阶段序列（通常为 PIPELINE_STAGES，§6.3 八阶段）。 */
  stages: readonly PipelineStage[]
  /** 当前阶段下标（progress.stage_index）；未知（<0）全部置灰。 */
  currentIndex: number
  className?: string
}

const NODE_STATE_CLASSES: Record<string, string> = {
  done: "border-primary bg-primary text-primary-foreground",
  current: "border-primary bg-background text-primary ring-4 ring-primary/15",
  pending: "border-border bg-muted text-muted-foreground",
}

const LABEL_STATE_CLASSES: Record<string, string> = {
  done: "text-foreground",
  current: "text-foreground font-medium",
  pending: "text-muted-foreground",
}

/**
 * 阶段步进条（设计 §6.4 自建组件，约百行 flex + token）。
 *
 * 完成=实心（带对勾）、当前=强调色描边、未到=灰（§6.3）；
 * 外层横向滚动适配窄屏，当前阶段标注中文名。
 */
export function Stepper({ stages, currentIndex, className }: StepperProps) {
  const states = stepperStates(currentIndex, stages.length)

  return (
    <div className={cn("overflow-x-auto pb-1", className)}>
      <ol aria-label="生产阶段" className="flex min-w-max items-start">
        {stages.map((stage, index) => {
          const state = states[index] ?? "pending"
          const isLast = index === stages.length - 1
          return (
            <li
              key={stage.key}
              aria-current={state === "current" ? "step" : undefined}
              className="flex items-start"
            >
              <div className="flex w-24 shrink-0 flex-col items-center gap-1.5">
                <span
                  data-stage={stage.key}
                  data-state={state}
                  aria-hidden="true"
                  className={cn(
                    "flex size-8 items-center justify-center rounded-full border transition-colors",
                    NODE_STATE_CLASSES[state],
                  )}
                >
                  {state === "done" && <Check className="size-4" />}
                </span>
                <span
                  className={cn(
                    "text-center text-xs leading-tight",
                    LABEL_STATE_CLASSES[state],
                  )}
                >
                  {stage.label}
                </span>
              </div>
              {!isLast && (
                <span
                  aria-hidden="true"
                  data-connector={state === "done" ? "done" : "pending"}
                  className={cn(
                    "mt-4 h-0.5 w-10 shrink-0 rounded-full",
                    state === "done" ? "bg-primary/60" : "bg-border",
                  )}
                />
              )}
            </li>
          )
        })}
      </ol>
    </div>
  )
}
