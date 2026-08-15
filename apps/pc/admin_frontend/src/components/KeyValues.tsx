import type { ReactNode } from "react"

import { cn } from "@/lib/utils"

export interface KeyValueItem {
  label: string
  value: ReactNode
  /** 值用等宽字体（ID、哈希、端点等）。 */
  mono?: boolean
}

interface KeyValuesProps {
  items: KeyValueItem[]
  className?: string
}

/**
 * 详情网格（设计 §6.4 自建组件）：两列 label/value 网格，替代
 * antd Descriptions 的语义分区。label 列收窄自适应，value 列占满。
 */
export function KeyValues({ items, className }: KeyValuesProps) {
  return (
    <dl
      className={cn(
        "grid grid-cols-[minmax(6rem,auto)_minmax(0,1fr)] gap-x-6 gap-y-2 text-sm",
        className,
      )}
    >
      {items.map((item) => (
        <div key={item.label} className="col-span-full grid col-start-1 grid-cols-subgrid">
          <dt className="text-muted-foreground">{item.label}</dt>
          <dd
            className={cn(
              "min-w-0 break-words",
              item.mono && "font-mono text-[13px]",
            )}
          >
            {item.value}
          </dd>
        </div>
      ))}
    </dl>
  )
}
