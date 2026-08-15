import { describe, expect, it } from "vitest"

import {
  derivePercent,
  inStagePercent,
  PIPELINE_STAGES,
  stageIndex,
  stageLabel,
  stepperStates,
  STAGE_ENTRY_PERCENT,
  unitCounterLabel,
} from "@/lib/progress"

/** 表驱动：与后端 test_job_progress.py 的语义用例镜像（§8.1 权重）。 */
describe("derivePercent", () => {
  it("八阶段权重表与后端 §8.1 一致", () => {
    expect(PIPELINE_STAGES).toHaveLength(8)
    expect(PIPELINE_STAGES.map((stage) => stage.key)).toEqual([
      "queued",
      "translation",
      "speech",
      "audio",
      "review",
      "packaging",
      "publishing",
      "complete",
    ])
    expect(STAGE_ENTRY_PERCENT).toEqual({
      queued: 0,
      translation: 0,
      speech: 45,
      audio: 90,
      review: 95,
      packaging: 97,
      publishing: 99,
      complete: 100,
    })
  })

  it.each([
    {
      name: "queued：等待 Worker，不确定",
      stage: "queued",
      done: null,
      total: null,
      percent: 0,
      indeterminate: true,
    },
    {
      name: "translation 1/3 → 15.0（失败任务停在翻译阶段的派生值）",
      stage: "translation",
      done: 1,
      total: 3,
      percent: 15.0,
      indeterminate: false,
    },
    {
      name: "translation 全部完成 → 45.0（进入 speech 权重）",
      stage: "translation",
      done: 5,
      total: 5,
      percent: 45.0,
      indeterminate: false,
    },
    {
      name: "speech 127/200 → 73.6（§8.4 示例）",
      stage: "speech",
      done: 127,
      total: 200,
      percent: 73.6,
      indeterminate: false,
    },
    {
      name: "speech 全部完成 → 90.0",
      stage: "speech",
      done: 40,
      total: 40,
      percent: 90.0,
      indeterminate: false,
    },
    {
      name: "audio：短促阶段不确定，锚定 90",
      stage: "audio",
      done: null,
      total: null,
      percent: 90,
      indeterminate: true,
    },
    {
      name: "review：固定阶段内 100%，总 97.0",
      stage: "review",
      done: null,
      total: null,
      percent: 97.0,
      indeterminate: false,
    },
    {
      name: "packaging：不确定，锚定 97",
      stage: "packaging",
      done: null,
      total: null,
      percent: 97,
      indeterminate: true,
    },
    {
      name: "publishing：不确定，锚定 99",
      stage: "publishing",
      done: null,
      total: null,
      percent: 99,
      indeterminate: true,
    },
    {
      name: "complete：恒 100",
      stage: "complete",
      done: null,
      total: null,
      percent: 100,
      indeterminate: false,
    },
    {
      name: "计划无单元的阶段退化为不确定（§8.1 注）",
      stage: "speech",
      done: 0,
      total: 0,
      percent: 45,
      indeterminate: true,
    },
  ])("$name", ({ stage, done, total, percent, indeterminate }) => {
    expect(derivePercent(stage, done, total)).toEqual({ percent, indeterminate })
  })

  it("计数高于总数时钳制到 1（防御陈旧 checkpoint）", () => {
    expect(derivePercent("translation", 7, 5)).toEqual({
      percent: 45.0,
      indeterminate: false,
    })
  })
})

describe("inStagePercent", () => {
  it.each([
    { stage: "translation", done: 1, total: 4, expected: 25 },
    { stage: "speech", done: 127, total: 200, expected: 63.5 },
    { stage: "review", done: null, total: null, expected: 100 },
    { stage: "complete", done: null, total: null, expected: 100 },
    { stage: "queued", done: null, total: null, expected: null },
    { stage: "audio", done: null, total: null, expected: null },
    { stage: "speech", done: 0, total: 0, expected: null },
  ])("$stage($done/$total) → $expected", ({ stage, done, total, expected }) => {
    expect(inStagePercent(stage, done, total)).toBe(expected)
  })
})

describe("unitCounterLabel", () => {
  it.each([
    { stage: "translation", done: 3, total: 5, expected: "已翻译 3/5 单元" },
    { stage: "speech", done: 127, total: 200, expected: "已合成 127/200 句" },
    { stage: "review", done: null, total: null, expected: null },
    { stage: "speech", done: 0, total: 0, expected: null },
  ])("$stage → $expected", ({ stage, done, total, expected }) => {
    expect(unitCounterLabel(stage, done, total)).toBe(expected)
  })
})

describe("stepperStates", () => {
  it("当前阶段前为 done、当前为 current、其后 pending", () => {
    expect(stepperStates(3)).toEqual([
      "done",
      "done",
      "done",
      "current",
      "pending",
      "pending",
      "pending",
      "pending",
    ])
  })

  it("未知阶段（-1）全部 pending", () => {
    expect(stepperStates(-1)).toEqual(Array.from({ length: 8 }, () => "pending"))
  })

  it("首阶段 current、其余 pending；末阶段前序全部 done 且自身 current", () => {
    expect(stepperStates(0)[0]).toBe("current")
    const last = stepperStates(7)
    expect(last.slice(0, 7).every((state) => state === "done")).toBe(true)
    expect(last[7]).toBe("current")
  })
})

describe("stage 元数据", () => {
  it("stageIndex / stageLabel 提供索引与中文名", () => {
    expect(stageIndex("speech")).toBe(2)
    expect(stageLabel("speech")).toBe("语音合成")
    expect(stageIndex("unknown")).toBe(-1)
    expect(stageLabel("unknown")).toBe("unknown")
  })
})
