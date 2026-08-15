/**
 * 工作台（设计 §5.1 `/`，§8.5 dashboard/summary 单次往返）：
 * - 概览卡片（文章 / 任务 / 发布 / 制品）；
 * - 文章库（链接结构页 + 删除文章 AlertDialog，输入文章 ID 确认）；
 * - 近期任务（§6.3 状态徽标 + 链接 /jobs/:id）；
 * - 发布制品与可重新发布制品；
 * - 发布器面板（绑定地址、风险提示、持久化进程状态、启停操作）。
 *
 * 数据全部来自 GET /api/dashboard/summary，发布器启停走既有
 * /api/publisher/* 端点；刷新为 5s 轮询（§2.2：SSE 仅任务详情页）。
 */

import { Link } from "react-router"
import { FileText, ListTodo, Package, Rocket, TriangleAlert } from "lucide-react"
import { toast } from "sonner"

import {
  useDashboardSummary,
  useRepublishArtifactMutation,
  useStartPublisherMutation,
  useStopPublisherMutation,
} from "@/api/hooks/dashboard"
import type {
  ArtifactPayload,
  DashboardSummaryPayload,
  PublishedPayload,
} from "@/api/dashboard"
import { KeyValues } from "@/components/KeyValues"
import { PageHeader } from "@/components/layout/PageHeader"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import {
  ArticleStatusBadge,
} from "@/features/articles/ArticleStatusBadge"
import { DeleteArticleDialog } from "@/features/articles/DeleteArticleDialog"
import { JobStatusBadge } from "@/features/jobs/JobStatusBadge"
import { stageLabel } from "@/lib/progress"
import { shortenHash } from "@/lib/hashes"
import { formatDateTime } from "@/lib/time"
import { cn } from "@/lib/utils"

/** 工作台轮询间隔（§2.2 非目标 5：列表用轮询，SSE 仅任务详情）。 */
const SUMMARY_POLL_INTERVAL_MS = 5000

function formatBytes(size: number): string {
  if (size >= 1024 * 1024) {
    return `${(size / (1024 * 1024)).toFixed(1)} MB`
  }
  if (size >= 1024) {
    return `${(size / 1024).toFixed(1)} KB`
  }
  return `${size} B`
}

function OverviewCards({ summary }: { summary: DashboardSummaryPayload }) {
  const cards = [
    {
      label: "文章",
      value: summary.articles.length,
      unit: "篇",
      icon: FileText,
    },
    {
      label: "生产任务",
      value: summary.jobs.length,
      unit: "个",
      icon: ListTodo,
    },
    {
      label: "当前发布",
      value: summary.published.length,
      unit: "个",
      icon: Rocket,
    },
    {
      label: "可重新发布制品",
      value: summary.artifacts.length,
      unit: "个",
      icon: Package,
    },
  ]
  return (
    <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
      {cards.map(({ label, value, unit, icon: Icon }) => (
        <Card key={label}>
          <CardContent className="flex items-center gap-3 pt-6">
            <span
              aria-hidden="true"
              className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary"
            >
              <Icon className="size-4" />
            </span>
            <div className="min-w-0">
              <p className="text-xs text-muted-foreground">{label}</p>
              <p className="text-xl font-semibold tabular-nums">
                {value}
                <span className="ml-1 text-xs font-normal text-muted-foreground">
                  {unit}
                </span>
              </p>
            </div>
          </CardContent>
        </Card>
      ))}
    </div>
  )
}

function EmptyHint({ children }: { children: string }) {
  return <p className="px-1 py-6 text-sm text-muted-foreground">{children}</p>
}

function ArticlesCard({ summary }: { summary: DashboardSummaryPayload }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>文章库</CardTitle>
        <CardDescription>{summary.articles.length} 篇（各文章最新修订）</CardDescription>
      </CardHeader>
      <CardContent className="space-y-2">
        {summary.articles.length === 0 ? (
          <EmptyHint>还没有文章。录入正文后将自动生成候选分句。</EmptyHint>
        ) : (
          summary.articles.map((article) => (
            <div
              key={article.article_id}
              className="flex items-center gap-3 rounded-lg border px-3 py-2.5"
            >
              <div className="min-w-0 flex-1">
                <Link
                  to={`/articles/${article.article_id}/revisions/${article.revision}`}
                  className="block truncate font-medium hover:text-primary hover:underline"
                >
                  {article.title}
                </Link>
                <p className="mt-0.5 text-xs text-muted-foreground">
                  修订 {article.revision} · {article.article_id.slice(0, 8)}
                </p>
              </div>
              <ArticleStatusBadge status={article.status} />
              <DeleteArticleDialog
                articleId={article.article_id}
                triggerLabel="删除"
                triggerVariant="ghost"
                triggerSize="xs"
                triggerTitle={`删除文章 ${article.article_id}`}
                triggerClassName="text-destructive hover:text-destructive"
              />
            </div>
          ))
        )}
      </CardContent>
    </Card>
  )
}

function RecentJobsCard({ summary }: { summary: DashboardSummaryPayload }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>近期任务</CardTitle>
        <CardDescription>
          {summary.jobs.length > 0 ? (
            <Link to="/jobs" className="hover:text-primary hover:underline">
              全部任务 →
            </Link>
          ) : (
            "确认文章结构后，生产任务会出现在这里"
          )}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-2">
        {summary.jobs.length === 0 ? (
          <EmptyHint>暂无任务。</EmptyHint>
        ) : (
          summary.jobs.map((job) => (
            <Link
              key={job.job_id}
              to={`/jobs/${job.job_id}`}
              className="flex items-center gap-3 rounded-lg border px-3 py-2.5 transition-colors hover:bg-accent/50"
            >
              <div className="min-w-0 flex-1">
                <p className="truncate font-medium">
                  {stageLabel(job.progress.stage)}
                </p>
                <p className="mt-0.5 text-xs text-muted-foreground">
                  {job.article_id.slice(0, 8)} · r{job.revision} · 尝试{" "}
                  {job.attempts}
                </p>
              </div>
              <JobStatusBadge status={job.status} />
            </Link>
          ))
        )}
      </CardContent>
    </Card>
  )
}

function PublishedCard({ published }: { published: PublishedPayload[] }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>当前已发布制品</CardTitle>
        <CardDescription>{published.length} 个</CardDescription>
      </CardHeader>
      <CardContent className="space-y-2">
        {published.length === 0 ? (
          <EmptyHint>还没有当前发布制品。</EmptyHint>
        ) : (
          published.map((item) => (
            <div
              key={item.package_id}
              className="rounded-lg border px-3 py-2.5"
            >
              <p className="truncate font-medium">{item.title}</p>
              <p className="mt-0.5 text-xs text-muted-foreground">
                正文修订 {item.revision} · 制品修订 {item.artifact_revision} ·{" "}
                {formatBytes(item.size)}
              </p>
              <p className="mt-1 font-mono text-[11px] text-muted-foreground">
                {shortenHash(item.sha256, 16)}
              </p>
            </div>
          ))
        )}
      </CardContent>
    </Card>
  )
}

function ArtifactsCard({ artifacts }: { artifacts: ArtifactPayload[] }) {
  const republishMutation = useRepublishArtifactMutation()

  const onRepublish = async (packageId: string) => {
    try {
      await republishMutation.mutateAsync(packageId)
      toast.success(`制品 ${packageId.slice(0, 8)} 已重新发布`)
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "重新发布失败，请重试",
      )
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>制品库</CardTitle>
        <CardDescription>成功构建后保留不可变制品</CardDescription>
      </CardHeader>
      <CardContent className="space-y-2">
        {artifacts.length === 0 ? (
          <EmptyHint>成功构建后会保留不可变制品。</EmptyHint>
        ) : (
          artifacts.map((artifact) => (
            <div
              key={artifact.package_id}
              className="flex items-center gap-3 rounded-lg border px-3 py-2.5"
            >
              <div className="min-w-0 flex-1">
                <p className="truncate font-medium font-mono text-[13px]">
                  {artifact.article_id.slice(0, 8)} · r{artifact.revision}/a
                  {artifact.artifact_revision}
                </p>
                <p className="mt-0.5 text-xs text-muted-foreground">
                  {artifact.state} · {formatBytes(artifact.size)}
                </p>
              </div>
              <Button
                variant="outline"
                size="xs"
                disabled={republishMutation.isPending}
                onClick={() => void onRepublish(artifact.package_id)}
              >
                重新发布
              </Button>
            </div>
          ))
        )}
      </CardContent>
    </Card>
  )
}

function PublisherCard({ summary }: { summary: DashboardSummaryPayload }) {
  const publisher = summary.publisher
  const startMutation = useStartPublisherMutation()
  const stopMutation = useStopPublisherMutation()
  const pending = startMutation.isPending || stopMutation.isPending

  const onToggle = async () => {
    try {
      if (publisher.running) {
        await stopMutation.mutateAsync()
        toast.success("局域网服务已停止")
      } else {
        await startMutation.mutateAsync()
        toast.success(`局域网服务已启动：${publisher.binding_url}`)
      }
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "发布器操作失败，请重试",
      )
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>局域网只读服务</CardTitle>
        <CardDescription>
          {summary.catalog_available
            ? "目录已生成。"
            : "尚无已发布制品；服务启动后目录仍会返回 404。"}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="flex items-center justify-between gap-3">
          <Badge
            className={cn(
              publisher.running
                ? "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400"
                : "bg-zinc-500/15 text-zinc-600 dark:text-zinc-300",
            )}
          >
            {publisher.running ? "运行中" : "已停止"}
          </Badge>
          <Button
            variant={publisher.running ? "destructive" : "default"}
            disabled={pending}
            onClick={() => void onToggle()}
          >
            {pending
              ? "处理中…"
              : publisher.running
                ? "停止局域网服务"
                : "启动局域网服务"}
          </Button>
        </div>

        <KeyValues
          items={[
            { label: "绑定地址", value: publisher.binding_url, mono: true },
            { label: "启动时间", value: formatDateTime(publisher.started_at) },
            {
              label: "进程 PID",
              value: publisher.pid === null ? "—" : String(publisher.pid),
            },
            {
              label: "最近退出码",
              value:
                publisher.last_exit_code === null
                  ? "—"
                  : String(publisher.last_exit_code),
            },
          ]}
        />

        <Alert variant="warning">
          <TriangleAlert aria-hidden="true" />
          <AlertTitle>风险提示</AlertTitle>
          <AlertDescription>
            此服务没有鉴权，只能在你信任的局域网中临时开启；同一网络内的
            设备可读取目录与全部已发布包。
          </AlertDescription>
        </Alert>
      </CardContent>
    </Card>
  )
}

function DashboardSkeleton() {
  return (
    <div className="space-y-6" aria-busy="true" aria-label="工作台加载中">
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        {Array.from({ length: 4 }, (_, index) => (
          <Skeleton key={index} className="h-20 w-full" />
        ))}
      </div>
      <div className="grid gap-6 lg:grid-cols-2">
        {Array.from({ length: 2 }, (_, index) => (
          <Skeleton key={index} className="h-64 w-full" />
        ))}
      </div>
    </div>
  )
}

export function DashboardPage() {
  const summaryQuery = useDashboardSummary({
    refetchInterval: SUMMARY_POLL_INTERVAL_MS,
  })
  const summary = summaryQuery.data

  return (
    <div className="space-y-6">
      <PageHeader
        title="工作台"
        breadcrumbs={[{ label: "工作台" }]}
        actions={
          <Button asChild>
            <Link to="/articles/new">录入文章</Link>
          </Button>
        }
      />

      {summaryQuery.isPending ? (
        <DashboardSkeleton />
      ) : summaryQuery.isError ? (
        <div
          role="alert"
          className="rounded-lg border border-destructive/50 bg-destructive/10 p-4 text-sm text-destructive"
        >
          工作台加载失败：
          {summaryQuery.error instanceof Error
            ? summaryQuery.error.message
            : "未知错误"}
        </div>
      ) : summary ? (
        <>
          {summary.verification_mode && (
            <Alert variant="warning">
              <TriangleAlert aria-hidden="true" />
              <AlertTitle>验证模式</AlertTitle>
              <AlertDescription>
                翻译与 TTS 当前为验证桩。生成结果会显式标注，不会调用
                DeepSeek 或加载 Qwen3-TTS。
              </AlertDescription>
            </Alert>
          )}

          <OverviewCards summary={summary} />

          <div className="grid gap-6 lg:grid-cols-2">
            <ArticlesCard summary={summary} />
            <RecentJobsCard summary={summary} />
          </div>

          <div className="grid gap-6 lg:grid-cols-2">
            <PublishedCard published={summary.published} />
            <ArtifactsCard artifacts={summary.artifacts} />
          </div>

          <PublisherCard summary={summary} />
        </>
      ) : null}
    </div>
  )
}
