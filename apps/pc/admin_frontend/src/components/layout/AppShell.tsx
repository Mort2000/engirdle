import {
  AudioLines,
  FileText,
  LayoutDashboard,
  ListTodo,
  Moon,
  PanelLeftClose,
  PanelLeftOpen,
  Sun,
  TriangleAlert,
} from "lucide-react"
import { useState } from "react"
import { NavLink, Outlet } from "react-router"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Toaster } from "@/components/ui/sonner"
import { cn } from "@/lib/utils"
import { useTheme } from "@/lib/theme"
import { useDashboardSummary } from "@/api/hooks/dashboard"

const NAV_ITEMS = [
  { to: "/", label: "工作台", icon: LayoutDashboard },
  { to: "/articles/new", label: "文章", icon: FileText },
  { to: "/jobs", label: "任务", icon: ListTodo },
  { to: "/voices", label: "声音配置", icon: AudioLines },
] as const

function ThemeToggle() {
  const { theme, toggleTheme } = useTheme()
  return (
    <Button
      variant="ghost"
      size="icon-sm"
      onClick={toggleTheme}
      aria-label={theme === "dark" ? "切换到亮色主题" : "切换到暗色主题"}
      title={theme === "dark" ? "切换到亮色主题" : "切换到暗色主题"}
    >
      {theme === "dark" ? <Sun /> : <Moon />}
    </Button>
  )
}

/** 全局 Toast 容器（§6.4：Sonner），主题跟随自建 ThemeProvider。 */
function AppToaster() {
  const { theme } = useTheme()
  return <Toaster theme={theme} position="bottom-right" />
}

/**
 * 应用框架布局（设计 §6.1）：可折叠左侧导航 + 内容区。
 *
 * 底部为主题切换与适配器状态徽标（§6.1：stub 验证模式警示）。
 * 徽标按 /api/dashboard/summary 的 verification_mode 门控——仅在翻译或
 * TTS 适配器为验证桩时渲染；查询加载中/失败（data 为 undefined）时不
 * 渲染，避免在真实适配器部署下误报。
 */
export function AppShell() {
  const [collapsed, setCollapsed] = useState(false)
  const summaryQuery = useDashboardSummary()
  const verificationMode = summaryQuery.data?.verification_mode ?? false

  return (
    <div className="flex min-h-screen bg-background">
      <aside
        data-collapsed={collapsed}
        className={cn(
          "sticky top-0 flex h-screen shrink-0 flex-col border-r bg-card transition-[width] duration-200",
          collapsed ? "w-14" : "w-56",
        )}
      >
        <div className="flex h-14 items-center gap-2 border-b px-3">
          <span
            aria-hidden="true"
            className="flex size-8 shrink-0 items-center justify-center rounded-lg bg-primary text-sm font-bold text-primary-foreground"
          >
            E
          </span>
          {!collapsed && (
            <span className="truncate text-sm font-semibold">Engirdle 管理端</span>
          )}
        </div>

        <nav aria-label="主导航" className="flex-1 space-y-1 px-2 py-4">
          {NAV_ITEMS.map(({ to, label, icon: Icon }) => (
            <NavLink
              key={to}
              to={to}
              end={to === "/"}
              title={collapsed ? label : undefined}
              className={({ isActive }) =>
                cn(
                  "flex items-center gap-3 rounded-md px-2.5 py-2 text-sm transition-colors",
                  "hover:bg-accent hover:text-accent-foreground",
                  isActive && "bg-accent font-medium text-accent-foreground",
                  collapsed && "justify-center px-0",
                )
              }
            >
              <Icon className="size-4 shrink-0" aria-hidden="true" />
              {!collapsed && <span className="truncate">{label}</span>}
            </NavLink>
          ))}
        </nav>

        <div className="space-y-2 border-t px-2 py-3">
          {!collapsed && verificationMode && (
            <Badge
              variant="outline"
              className="w-full justify-center gap-1.5 border-amber-500/50 text-amber-600 dark:text-amber-400"
              title="翻译 / TTS 适配器运行于验证桩模式，不会调用真实服务（详见工作台提示）"
            >
              <TriangleAlert aria-hidden="true" />
              验证桩模式
            </Badge>
          )}
          <div
            className={cn(
              "flex items-center gap-1",
              collapsed ? "flex-col" : "justify-between",
            )}
          >
            <ThemeToggle />
            <Button
              variant="ghost"
              size="icon-sm"
              onClick={() => setCollapsed((value) => !value)}
              aria-label={collapsed ? "展开侧边栏" : "折叠侧边栏"}
              title={collapsed ? "展开侧边栏" : "折叠侧边栏"}
            >
              {collapsed ? <PanelLeftOpen /> : <PanelLeftClose />}
            </Button>
          </div>
        </div>
      </aside>

      <main className="min-w-0 flex-1">
        <div className="mx-auto w-full max-w-6xl px-6 py-8">
          <Outlet />
        </div>
      </main>

      <AppToaster />
    </div>
  )
}
