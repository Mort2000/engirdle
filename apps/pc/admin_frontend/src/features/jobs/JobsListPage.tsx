/**
 * 任务列表页（设计 §5.1 /jobs，§12 步骤 4 末项）：
 * TanStack Query 5s 轮询 + §6.3 状态徽标 + 进度概览 + 空态与加载骨架。
 * 列表数据含派生 progress（§8.5），点击任务进入详情页。
 */

import { Link } from "react-router"

import { useJobsList } from "@/api/hooks/jobs"
import { PageHeader } from "@/components/layout/PageHeader"
import { Progress } from "@/components/ui/progress"
import { Skeleton } from "@/components/ui/skeleton"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { JobStatusBadge } from "@/features/jobs/JobStatusBadge"
import { stageLabel } from "@/lib/progress"
import { formatDateTime } from "@/lib/time"

/** 列表轮询间隔（本阶段 spec：5s；SSE 仅覆盖任务详情页，§2.2）。 */
const LIST_POLL_INTERVAL_MS = 5000

function JobsTableSkeleton() {
  return (
    <div className="space-y-2" aria-busy="true" aria-label="任务列表加载中">
      {Array.from({ length: 5 }, (_, index) => (
        <Skeleton key={index} className="h-12 w-full" />
      ))}
    </div>
  )
}

export function JobsListPage() {
  const jobsQuery = useJobsList({ refetchInterval: LIST_POLL_INTERVAL_MS })
  const jobs = jobsQuery.data ?? []

  return (
    <div className="space-y-6">
      <PageHeader
        title="任务列表"
        breadcrumbs={[{ label: "工作台", to: "/" }, { label: "任务" }]}
      />

      {jobsQuery.isPending ? (
        <JobsTableSkeleton />
      ) : jobsQuery.isError ? (
        <div
          role="alert"
          className="rounded-lg border border-destructive/50 bg-destructive/10 p-4 text-sm text-destructive"
        >
          任务列表加载失败：{jobsQuery.error instanceof Error ? jobsQuery.error.message : "未知错误"}
        </div>
      ) : jobs.length === 0 ? (
        <div className="rounded-xl border bg-card p-10 text-center">
          <p className="font-medium">暂无任务</p>
          <p className="mt-1 text-sm text-muted-foreground">
            从工作台或文章结构页提交构建后，任务会出现在这里。
          </p>
        </div>
      ) : (
        <div className="overflow-hidden rounded-xl border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>任务</TableHead>
                <TableHead>文章</TableHead>
                <TableHead>状态</TableHead>
                <TableHead>阶段</TableHead>
                <TableHead className="w-44">进度</TableHead>
                <TableHead>尝试</TableHead>
                <TableHead>创建时间</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {jobs.map((job) => (
                <TableRow key={job.job_id}>
                  <TableCell>
                    <Link
                      to={`/jobs/${job.job_id}`}
                      className="font-mono text-[13px] text-primary hover:underline"
                    >
                      {job.job_id.slice(0, 8)}
                    </Link>
                  </TableCell>
                  <TableCell className="font-mono text-[13px] text-muted-foreground">
                    {job.article_id.slice(0, 8)} · r{job.revision}
                  </TableCell>
                  <TableCell>
                    <JobStatusBadge status={job.status} />
                  </TableCell>
                  <TableCell className="text-muted-foreground">
                    {stageLabel(job.progress.stage)}
                  </TableCell>
                  <TableCell>
                    <div className="flex items-center gap-2">
                      <Progress
                        value={job.progress.indeterminate ? undefined : job.progress.percent}
                        className="h-1.5 w-24"
                        aria-label={`任务 ${job.job_id.slice(0, 8)} 进度`}
                      />
                      <span className="text-xs tabular-nums text-muted-foreground">
                        {job.progress.percent.toFixed(1)}%
                      </span>
                    </div>
                  </TableCell>
                  <TableCell className="tabular-nums">{job.attempts}</TableCell>
                  <TableCell className="text-muted-foreground">
                    {formatDateTime(job.created_at)}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  )
}
