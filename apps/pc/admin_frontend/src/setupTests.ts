import "@testing-library/jest-dom/vitest"

import { cleanup } from "@testing-library/react"
import { afterEach } from "vitest"

// vitest 未开启 globals，Testing Library 无法自动注册清理钩子，
// 显式清理避免跨用例 DOM 泄漏导致的重复元素查询。
afterEach(() => {
  cleanup()
})

// jsdom 缺少布局 API：CodeMirror 6 的选区/光标测量依赖 Range 的
// getClientRects/getBoundingClientRect（真实浏览器均提供）。这里按
// CodeMirror 官方测试口径补零值实现，仅影响测试环境的几何测量。
if (!Range.prototype.getClientRects) {
  Range.prototype.getClientRects = () =>
    ({ length: 0, item: () => null }) as unknown as DOMRectList
}
if (!Range.prototype.getBoundingClientRect) {
  Range.prototype.getBoundingClientRect = () =>
    DOMRect.fromRect({ x: 0, y: 0, width: 0, height: 0 }) as DOMRect
}
