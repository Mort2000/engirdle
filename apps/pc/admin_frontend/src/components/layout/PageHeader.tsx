import { ChevronRight } from "lucide-react"
import { Link } from "react-router"
import type { ReactNode } from "react"

export interface BreadcrumbItem {
  label: string
  to?: string
}

interface PageHeaderProps {
  title: string
  breadcrumbs: BreadcrumbItem[]
  /** 右上主操作区骨架（设计 §6.1）。 */
  actions?: ReactNode
}

/**
 * 页面骨架（设计 §6.1）：面包屑 + 页标题 + 右上主操作按钮区。
 * 语义上替换旧页面的 page-heading 分区。
 */
export function PageHeader({ title, breadcrumbs, actions }: PageHeaderProps) {
  return (
    <header className="flex flex-col gap-4 pb-2 md:flex-row md:items-end md:justify-between">
      <div className="min-w-0 space-y-1.5">
        <nav aria-label="面包屑">
          <ol className="flex flex-wrap items-center gap-1 text-xs text-muted-foreground">
            {breadcrumbs.map((crumb, index) => {
              const isLast = index === breadcrumbs.length - 1
              return (
                <li key={`${crumb.label}-${index}`} className="flex items-center gap-1">
                  {index > 0 && (
                    <ChevronRight aria-hidden="true" className="size-3 opacity-50" />
                  )}
                  {isLast || !crumb.to ? (
                    <span aria-current={isLast ? "page" : undefined}>{crumb.label}</span>
                  ) : (
                    <Link to={crumb.to} className="hover:text-foreground">
                      {crumb.label}
                    </Link>
                  )}
                </li>
              )
            })}
          </ol>
        </nav>
        <h1 className="truncate text-2xl font-semibold tracking-tight">{title}</h1>
      </div>
      {actions && <div className="flex shrink-0 items-center gap-2">{actions}</div>}
    </header>
  )
}
