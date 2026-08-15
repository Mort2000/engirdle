interface PagePlaceholderProps {
  title: string
  description: string
}

/**
 * 脚手架阶段的占位页骨架：页标题 + 说明。
 * 各功能页接入后（设计 §12 步骤 4）逐步替换为真实实现。
 */
export function PagePlaceholder({ title, description }: PagePlaceholderProps) {
  return (
    <main className="mx-auto flex w-full max-w-3xl flex-col gap-4 px-6 py-16">
      <h1 className="text-2xl font-semibold tracking-tight">{title}</h1>
      <p className="text-sm text-muted-foreground">{description}</p>
      <div aria-hidden="true" className="h-1.5 w-24 rounded-full bg-primary/30" />
    </main>
  )
}
