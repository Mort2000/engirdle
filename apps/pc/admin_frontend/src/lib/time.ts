/**
 * 时间展示纯函数（设计 §8.4：心跳相对时间“3 秒前”）。
 *
 * 管理端为单用户本地工具，中文相对时间自实现即可，无需引入
 * Intl.RelativeTimeFormat 的完整语义；绝对时间保持 ISO 输入的
 * 本地化渲染。
 */

const MINUTE_SECONDS = 60
const HOUR_SECONDS = 60 * MINUTE_SECONDS
const DAY_SECONDS = 24 * HOUR_SECONDS

/**
 * 相对时间：小于 1 分钟按秒，其后按分钟/小时/天；无法解析或为空
 * 返回 fallback（默认"—"）。未来时间（时钟偏差）按“刚刚”处理。
 */
export function formatRelativeTime(
  isoTime: string | null | undefined,
  now: Date | number = new Date(),
  fallback = "—",
): string {
  if (!isoTime) {
    return fallback
  }
  const time = new Date(isoTime).getTime()
  if (Number.isNaN(time)) {
    return fallback
  }
  const nowMs = now instanceof Date ? now.getTime() : now
  const deltaSeconds = Math.floor((nowMs - time) / 1000)
  if (deltaSeconds < MINUTE_SECONDS) {
    return deltaSeconds <= 1 ? "刚刚" : `${deltaSeconds} 秒前`
  }
  if (deltaSeconds < HOUR_SECONDS) {
    return `${Math.floor(deltaSeconds / MINUTE_SECONDS)} 分钟前`
  }
  if (deltaSeconds < DAY_SECONDS) {
    return `${Math.floor(deltaSeconds / HOUR_SECONDS)} 小时前`
  }
  return `${Math.floor(deltaSeconds / DAY_SECONDS)} 天前`
}

const DATE_TIME_FORMAT = new Intl.DateTimeFormat("zh-CN", {
  dateStyle: "medium",
  timeStyle: "medium",
})

/** 绝对时间（创建/起止时间）；无法解析原样返回，空值显示占位符。 */
export function formatDateTime(
  isoTime: string | null | undefined,
  placeholder = "—",
): string {
  if (!isoTime) {
    return placeholder
  }
  const time = new Date(isoTime)
  if (Number.isNaN(time.getTime())) {
    return isoTime
  }
  return DATE_TIME_FORMAT.format(time)
}
