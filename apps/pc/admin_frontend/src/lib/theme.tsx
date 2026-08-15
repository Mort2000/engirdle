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
 * - 仅在用户显式切换时持久化偏好到 localStorage；未选择前始终跟随系统
 *   prefers-color-scheme（含运行期间的系统主题变化），系统推导值不写入
 *   存储，避免首次访问即锁定推导结果。
 */
export type Theme = "light" | "dark"

const STORAGE_KEY = "engirdle-admin-theme"

const ThemeContext = createContext<{
  theme: Theme
  toggleTheme: () => void
} | null>(null)

function storedTheme(): Theme | null {
  const stored = window.localStorage.getItem(STORAGE_KEY)
  return stored === "light" || stored === "dark" ? stored : null
}

function systemTheme(): Theme {
  return window.matchMedia?.("(prefers-color-scheme: dark)").matches
    ? "dark"
    : "light"
}

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [theme, setTheme] = useState<Theme>(() => storedTheme() ?? systemTheme())

  useEffect(() => {
    document.documentElement.classList.toggle("dark", theme === "dark")
  }, [theme])

  useEffect(() => {
    // 没有显式选择时持续跟随系统主题；一旦偏好被写入即停止跟随。
    if (storedTheme() !== null) {
      return
    }
    const query = window.matchMedia?.("(prefers-color-scheme: dark)")
    if (!query) {
      return
    }
    const followSystem = () => setTheme(systemTheme())
    query.addEventListener("change", followSystem)
    return () => query.removeEventListener("change", followSystem)
  }, [theme])

  const toggleTheme = () => {
    const next: Theme = theme === "dark" ? "light" : "dark"
    window.localStorage.setItem(STORAGE_KEY, next)
    setTheme(next)
  }

  return (
    <ThemeContext.Provider value={{ theme, toggleTheme }}>
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
