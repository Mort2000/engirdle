import { act, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

import { ThemeProvider, useTheme } from "@/lib/theme"

const STORAGE_KEY = "engirdle-admin-theme"

type SystemListener = (event: { matches: boolean }) => void

/** Stub window.matchMedia with a controllable prefers-color-scheme query. */
function mockSystemTheme(initialDark: boolean) {
  const listeners = new Set<SystemListener>()
  let dark = initialDark
  vi.stubGlobal(
    "matchMedia",
    vi.fn().mockReturnValue({
      get matches() {
        return dark
      },
      addEventListener: (_type: string, listener: SystemListener) =>
        listeners.add(listener),
      removeEventListener: (_type: string, listener: SystemListener) =>
        listeners.delete(listener),
    }),
  )
  return {
    setDark(next: boolean) {
      dark = next
      listeners.forEach((listener) => listener({ matches: next }))
    },
  }
}

function ThemeProbe() {
  const { theme, toggleTheme } = useTheme()
  return (
    <button type="button" data-testid={theme} onClick={toggleTheme}>
      当前主题: {theme}
    </button>
  )
}

afterEach(() => {
  window.localStorage.clear()
  document.documentElement.classList.remove("dark")
  vi.unstubAllGlobals()
})

describe("ThemeProvider", () => {
  it("无存储偏好时默认跟随系统深色且不写入存储", () => {
    mockSystemTheme(true)

    render(
      <ThemeProvider>
        <ThemeProbe />
      </ThemeProvider>,
    )

    expect(document.documentElement).toHaveClass("dark")
    expect(screen.getByTestId("dark")).toBeInTheDocument()
    // 系统推导值不持久化：首次访问不锁定主题，系统变化仍被跟随。
    expect(window.localStorage.getItem(STORAGE_KEY)).toBeNull()
  })

  it("未显式选择时运行期间跟随系统主题变化", () => {
    const system = mockSystemTheme(true)

    render(
      <ThemeProvider>
        <ThemeProbe />
      </ThemeProvider>,
    )

    act(() => system.setDark(false))

    expect(screen.getByTestId("light")).toBeInTheDocument()
    expect(document.documentElement).not.toHaveClass("dark")
    expect(window.localStorage.getItem(STORAGE_KEY)).toBeNull()
  })

  it("切换主题会同步 .dark class 并持久化", () => {
    mockSystemTheme(true)
    render(
      <ThemeProvider>
        <ThemeProbe />
      </ThemeProvider>,
    )

    fireEvent.click(screen.getByRole("button"))

    expect(document.documentElement).not.toHaveClass("dark")
    expect(screen.getByTestId("light")).toBeInTheDocument()
    expect(window.localStorage.getItem(STORAGE_KEY)).toBe("light")
  })

  it("已持久化的偏好优先于系统偏好", () => {
    mockSystemTheme(false)
    window.localStorage.setItem(STORAGE_KEY, "dark")

    render(
      <ThemeProvider>
        <ThemeProbe />
      </ThemeProvider>,
    )

    expect(document.documentElement).toHaveClass("dark")
    expect(screen.getByTestId("dark")).toBeInTheDocument()
  })

  it("显式选择后不再跟随系统主题变化", () => {
    const system = mockSystemTheme(true)
    render(
      <ThemeProvider>
        <ThemeProbe />
      </ThemeProvider>,
    )

    fireEvent.click(screen.getByRole("button"))
    act(() => system.setDark(true))

    expect(screen.getByTestId("light")).toBeInTheDocument()
    expect(document.documentElement).not.toHaveClass("dark")
  })
})
