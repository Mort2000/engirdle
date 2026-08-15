import { describe, expect, it } from "vitest"

import { formatDateTime, formatRelativeTime } from "@/lib/time"

const NOW = new Date("2026-08-15T12:00:00+00:00")

describe("formatRelativeTime", () => {
  it.each([
    { name: "3 秒前", iso: "2026-08-15T11:59:57+00:00", expected: "3 秒前" },
    { name: "59 秒前", iso: "2026-08-15T11:59:01+00:00", expected: "59 秒前" },
    { name: "1 分钟内按刚刚", iso: "2026-08-15T11:59:59.5+00:00", expected: "刚刚" },
    { name: "整分钟", iso: "2026-08-15T11:58:30+00:00", expected: "1 分钟前" },
    { name: "5 分钟前", iso: "2026-08-15T11:55:00+00:00", expected: "5 分钟前" },
    { name: "2 小时前", iso: "2026-08-15T10:00:00+00:00", expected: "2 小时前" },
    { name: "3 天前", iso: "2026-08-12T11:00:00+00:00", expected: "3 天前" },
    { name: "未来时间按刚刚（时钟偏差容忍）", iso: "2026-08-15T12:00:10+00:00", expected: "刚刚" },
  ])("$name", ({ iso, expected }) => {
    expect(formatRelativeTime(iso, NOW)).toBe(expected)
  })

  it("空值与非法输入返回占位符", () => {
    expect(formatRelativeTime(null, NOW)).toBe("—")
    expect(formatRelativeTime(undefined, NOW)).toBe("—")
    expect(formatRelativeTime("not-a-date", NOW)).toBe("—")
  })
})

describe("formatDateTime", () => {
  it("渲染本地化绝对时间（含年份与时分秒）", () => {
    const formatted = formatDateTime("2026-08-15T08:00:00+00:00")
    expect(formatted).toMatch(/2026/)
    expect(formatted).toMatch(/\d{1,2}:\d{2}:\d{2}/)
  })

  it("空值显示占位符，非法输入原样返回", () => {
    expect(formatDateTime(null)).toBe("—")
    expect(formatDateTime("raw")).toBe("raw")
  })
})
