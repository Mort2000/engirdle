import {
  createContext,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react"

/**
 * 主题 Provider（设计 §6.2）：
 * - `.dark` class 策略切换 <html>，与 globals.css 的 @custom-variant 对应；
 * - 偏好持久化到 localStorage，默认跟随系统 prefers-color-scheme。
 */
export type Theme = "light" | "dark"

const STORAGE_KEY = "engirdle-admin-theme"

const ThemeContext = createContext<{
  theme: Theme
  toggleTheme: () => void
} | null>(null)

function initialTheme(): Theme {
  const stored = window.localStorage.getItem(STORAGE_KEY)
  if (stored === "light" || stored === "dark") {
    return stored
  }
  return window.matchMedia?.("(prefers-color-scheme: dark)").matches
    ? "dark"
    : "light"
}

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [theme, setTheme] = useState<Theme>(initialTheme)

  useEffect(() => {
    document.documentElement.classList.toggle("dark", theme === "dark")
    window.localStorage.setItem(STORAGE_KEY, theme)
  }, [theme])

  return (
    <ThemeContext.Provider
      value={{
        theme,
        toggleTheme: () =>
          setTheme((current) => (current === "dark" ? "light" : "dark")),
      }}
    >
      {children}
    </ThemeContext.Provider>
  )
}

export function useTheme() {
  const context = useContext(ThemeContext)
  if (!context) {
    throw new Error("useTheme 必须在 ThemeProvider 内使用")
  }
  return context
}
