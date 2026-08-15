/**
 * turndown-plugin-gfm 无官方类型包（npm 上不存在 @types/turndown-plugin-gfm），
 * 按其 dist 入口的实际形状声明最小模块类型：导出插件工厂，经
 * TurndownService.use 安装。
 */

declare module "turndown-plugin-gfm" {
  import type TurndownService from "turndown"

  export type GfmPlugin = (turndownService: TurndownService) => void

  export const gfm: GfmPlugin
  export const highlightedCodeBlock: GfmPlugin
  export const strikethrough: GfmPlugin
  export const tables: GfmPlugin
  export const taskListItems: GfmPlugin
}
