/**
 * 哈希/长标识符展示纯函数：界面上只展示前缀 + 省略号，
 * 完整值由详情/tooltip 承载。
 */

/** 截取前 keep 个字符；超长时追加省略号，空值返回占位符。 */
export function shortenHash(
  value: string | null | undefined,
  keep = 12,
  placeholder = "—",
): string {
  if (!value) {
    return placeholder
  }
  return value.length > keep ? `${value.slice(0, keep)}…` : value
}
