import { fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

import { ThemeProvider, useTheme } from "@/lib/theme"

const STORAGE_KEY = "engirdle-admin-theme"

function mockSystemTheme(dark: boolean) {
  vi.stubGlobal(
    "matchMedia",
    vi.fn().mockReturnValue({ matches: dark, addEventListener: vi.fn() }),
  )
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
  it("无存储偏好时默认跟随系统深色", () => {
    mockSystemTheme(true)

    render(
      <ThemeProvider>
        <ThemeProbe />
      </ThemeProvider>,
    )

    expect(document.documentElement).toHaveClass("dark")
    expect(screen.getByTestId("dark")).toBeInTheDocument()
    expect(window.localStorage.getItem(STORAGE_KEY)).toBe("dark")
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
})
