import "@testing-library/jest-dom/vitest"

import { cleanup } from "@testing-library/react"
import { afterEach } from "vitest"

// vitest 未开启 globals，Testing Library 无法自动注册清理钩子，
// 显式清理避免跨用例 DOM 泄漏导致的重复元素查询。
afterEach(() => {
  cleanup()
})
