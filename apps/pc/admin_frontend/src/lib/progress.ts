/**
 * 任务进度纯函数（设计 §8.1）。
 *
 * 权重表与后端 `admin_web/progress.py` 的 `STAGE_ENTRY_PERCENT` 语义一致：
 * 数值为“进入该阶段时的累计百分比”，为展示常数、集中定义便于调整。
 * 前端用同一张表驱动 Stepper 与 Progress 条，保证与服务端派生的
 * `percent` 字段不漂移（表驱动测试镜像后端用例）。
 */

export interface PipelineStage {
  key: string
  /** 阶段中文名（Stepper 标注，设计 §8.4）。 */
  label: string
}

/** 8 阶段顺序（§6.3），索引直接对应后端 progress.stage_index。 */
export const PIPELINE_STAGES: readonly PipelineStage[] = [
  { key: "queued", label: "排队" },
  { key: "translation", label: "翻译" },
  { key: "speech", label: "语音合成" },
  { key: "audio", label: "音频处理" },
  { key: "review", label: "人工审阅" },
  { key: "packaging", label: "打包" },
  { key: "publishing", label: "发布" },
  { key: "complete", label: "完成" },
] as const

/** 进入各阶段时的累计权重（%），与后端 §8.1 表一致。 */
export const STAGE_ENTRY_PERCENT: Readonly<Record<string, number>> = {
  queued: 0,
  translation: 0,
  speech: 45,
  audio: 90,
  review: 95,
  packaging: 97,
  publishing: 99,
  complete: 100,
}

/** 阶段内百分比语义：null 表示该阶段无单元刻度，用 indeterminate 动画。 */
export type StageUnitSemantics = "units" | "fixed-full" | "none"

const STAGE_SEMANTICS: Readonly<Record<string, StageUnitSemantics>> = {
  queued: "none",
  translation: "units",
  speech: "units",
  audio: "none",
  review: "fixed-full",
  packaging: "none",
  publishing: "none",
  complete: "fixed-full",
}

export function stageIndex(key: string): number {
  return PIPELINE_STAGES.findIndex((stage) => stage.key === key)
}

export function stageLabel(key: string): string {
  return PIPELINE_STAGES[stageIndex(key)]?.label ?? key
}

export function stageSemantics(key: string): StageUnitSemantics {
  return STAGE_SEMANTICS[key] ?? "none"
}

export interface DerivedPercent {
  /** 总百分比 = 进入权重 + 阶段内比例 × 权重跨度，保留 1 位小数。 */
  percent: number
  /** 无刻度阶段（排队/音频/打包/发布）为 true。 */
  indeterminate: boolean
}

/**
 * 由阶段与单元计数派生总百分比（镜像后端 derive_job_progress）。
 *
 * 无单元语义的阶段固定为进入权重并标记 indeterminate；review 阶段内
 * 恒为 100%（仅等待人工）；complete 恒为 100%。单元阶段计划数为 0 时
 * 退化为 indeterminate（§8.1 注：无单元则不可度量）。
 */
export function derivePercent(
  stage: string,
  doneUnits: number | null,
  totalUnits: number | null,
): DerivedPercent {
  const index = stageIndex(stage)
  const entry = STAGE_ENTRY_PERCENT[stage] ?? 0
  const nextEntry =
    index >= 0 && index < PIPELINE_STAGES.length - 1
      ? (STAGE_ENTRY_PERCENT[PIPELINE_STAGES[index + 1]!.key] ?? 100)
      : 100

  let inStage = 0
  let indeterminate = true
  if (STAGE_SEMANTICS[stage] === "units") {
    if ((totalUnits ?? 0) > 0) {
      inStage = Math.min(Math.max((doneUnits ?? 0) / (totalUnits as number), 0), 1)
      indeterminate = false
    }
  } else if (STAGE_SEMANTICS[stage] === "fixed-full") {
    inStage = 1
    indeterminate = false
  }
  const percent = Math.round((entry + inStage * (nextEntry - entry)) * 10) / 10
  return { percent, indeterminate }
}

/**
 * 阶段内百分比（0–100）；null 表示 indeterminate 动画（设计 §8.4）。
 */
export function inStagePercent(
  stage: string,
  doneUnits: number | null,
  totalUnits: number | null,
): number | null {
  if (stageSemantics(stage) === "fixed-full") {
    return 100
  }
  if (stageSemantics(stage) === "units" && (totalUnits ?? 0) > 0) {
    const fraction = (doneUnits ?? 0) / (totalUnits as number)
    return Math.round(Math.min(Math.max(fraction, 0), 1) * 1000) / 10
  }
  return null
}

/**
 * 实时计数文案（如“已合成 127/200 句”，设计 §8.4）；无单元刻度返回 null。
 */
export function unitCounterLabel(
  stage: string,
  doneUnits: number | null,
  totalUnits: number | null,
): string | null {
  if ((totalUnits ?? 0) <= 0) {
    return null
  }
  const done = doneUnits ?? 0
  const total = totalUnits as number
  if (stage === "translation") {
    return `已翻译 ${done}/${total} 单元`
  }
  if (stage === "speech") {
    return `已合成 ${done}/${total} 句`
  }
  return null
}

export type StepperStageState = "done" | "current" | "pending"

/**
 * Stepper 节点状态：完成=实心、当前=强调色描边、未到=灰（§6.3）。
 * 未知阶段（index < 0）全部 pending。
 */
export function stepperStates(
  currentIndex: number,
  count: number = PIPELINE_STAGES.length,
): StepperStageState[] {
  return Array.from({ length: count }, (_, index) => {
    if (currentIndex < 0 || index < currentIndex) {
      return currentIndex < 0 ? "pending" : "done"
    }
    return index === currentIndex ? "current" : "pending"
  })
}

/** 后端 progress 载荷的最小接口（§8.2），供展示层消费。 */
export interface ProgressLike {
  stage: string
  stage_index: number
  percent: number
  done_units: number | null
  total_units: number | null
  indeterminate: boolean
}
