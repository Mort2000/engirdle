/**
 * 任务详情页（设计 §5.1 /jobs/:id，§8.4 自上而下）：
 * 页头（ID/状态/尝试/时间/重试/发布）→ 进度面板（Stepper + Progress +
 * 计数 + 心跳）→ 详情面板（KeyValues：适配器/配置快照分组/处理计数）→
 * 失败面板 → 译文审阅（句级三列 + 表格 cell 级）→ 音频审阅。
 *
 * 实时性：useJobStream 以 SSE 驱动缓存更新，断连降级 5s 轮询；
 * 处理计数经 structure-report 端点获取（§8.5）。
 */

import { Link, useParams } from "react-router"
import { CircleCheck, RotateCcw, Rocket, TriangleAlert } from "lucide-react"
import { toast } from "sonner"

import {
  isAudioReadyStatus,
  isTerminalStatus,
  type SentenceTranslationPayload,
  type TableTranslationPayload,
} from "@/api/jobs"
import {
  useAudioReview,
  useJobDetail,
  useJobTranslations,
  usePublishJobMutation,
  useRetryJobMutation,
  useStructureReport,
} from "@/api/hooks/jobs"
import { useJobStream } from "@/api/hooks/useJobStream"
import { KeyValues, type KeyValueItem } from "@/components/KeyValues"
import { PageHeader } from "@/components/layout/PageHeader"
import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { AudioReviewPanel } from "@/features/jobs/AudioReviewPanel"
import { JobProgressPanel } from "@/features/jobs/JobProgressPanel"
import { JobStatusBadge } from "@/features/jobs/JobStatusBadge"
import { TranslationReviewPanel } from "@/features/jobs/TranslationReviewPanel"
import { formatDateTime } from "@/lib/time"
import type { JobDetailPayload } from "@/api/jobs"

function shorten(value: string, max = 120): string {
  return value.length > max ? `${value.slice(0, max)}…` : value
}

function configItems(group: Record<string, unknown>, labels: Record<string, string>): KeyValueItem[] {
  return Object.entries(group)
    .filter(([, value]) => value !== null && value !== undefined)
    .map(([key, value]) => ({
      label: labels[key] ?? key,
      value: shorten(String(value)),
      mono: key.includes("sha256") || key === "endpoint" || key === "model",
    }))
}

function DetailGrid({ job }: { job: JobDetailPayload }) {
  const report = useStructureReport(job.article_id, job.revision)
  const snapshot = job.config_snapshot
  const stubMode =
    job.translation_adapter.includes("stub") || job.speech_adapter.includes("stub")

  return (
    <div className="grid gap-6 lg:grid-cols-2">
      <Card>
        <CardHeader>
          <CardTitle>任务信息</CardTitle>
        </CardHeader>
        <CardContent>
          <KeyValues
            items={[
              { label: "任务 ID", value: job.job_id, mono: true },
              { label: "文章", value: `${job.article_id} · r${job.revision}`, mono: true },
              { label: "尝试次数", value: String(job.attempts) },
              { label: "创建时间", value: formatDateTime(job.created_at) },
              { label: "开始时间", value: formatDateTime(job.started_at) },
              { label: "结束时间", value: formatDateTime(job.finished_at) },
            ]}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>适配器</CardTitle>
          <CardDescription>
            {stubMode ? "验证桩模式：当前输出只用于全流程验证。" : "生产管线适配器配置。"}
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <KeyValues
            items={[
              { label: "翻译", value: job.translation_adapter, mono: true },
              { label: "TTS", value: job.speech_adapter, mono: true },
            ]}
          />
          {stubMode && (
            <p className="flex items-start gap-2 rounded-lg bg-amber-500/10 p-3 text-xs text-amber-600 dark:text-amber-400">
              <TriangleAlert aria-hidden="true" className="mt-0.5 size-3.5 shrink-0" />
              翻译 / TTS 适配器运行于验证桩，产物不用于发布。
            </p>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>翻译配置</CardTitle>
        </CardHeader>
        <CardContent>
          <KeyValues
            items={configItems(snapshot.translation, {
              adapter: "适配器",
              provider: "提供商",
              endpoint: "端点",
              model: "模型",
              thinking: "思考模式",
              reasoning_effort: "推理力度",
              prompt: "提示词",
            })}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>语音配置</CardTitle>
        </CardHeader>
        <CardContent>
          <KeyValues
            items={configItems(snapshot.speech, {
              adapter: "适配器",
              custom_voice_model: "自定义模型",
              base_model: "基础模型",
              generation: "生成参数",
              voice_profile: "声音档案",
              anchor_sha256: "锚点哈希",
            })}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>音频编码</CardTitle>
        </CardHeader>
        <CardContent>
          <KeyValues
            items={[
              { label: "编码", value: snapshot.audio_encoding.codec },
              { label: "码率", value: `${snapshot.audio_encoding.bitrate_kbps} kbps` },
              { label: "响度目标", value: `${snapshot.audio_encoding.loudness_target_lufs} LUFS` },
              { label: "真峰值", value: `${snapshot.audio_encoding.true_peak_dbfs} dBFS` },
              { label: "响度范围", value: `${snapshot.audio_encoding.loudness_range_lu} LU` },
            ]}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>处理计数</CardTitle>
          <CardDescription>代码块不进入任何 LLM 请求或 TTS 调用。</CardDescription>
        </CardHeader>
        <CardContent>
          {report.isPending ? (
            <Skeleton className="h-20 w-full" />
          ) : report.isError ? (
            <p className="text-sm text-muted-foreground">处理计数加载失败。</p>
          ) : (
            <KeyValues
              items={[
                { label: "翻译句数", value: String(report.data.processing_counts.translated_sentences) },
                { label: "翻译表数", value: String(report.data.processing_counts.translated_tables) },
                { label: "跳过代码块", value: String(report.data.processing_counts.skipped_code_blocks) },
                { label: "朗读句数", value: String(report.data.processing_counts.narrated_sentences) },
              ]}
            />
          )}
        </CardContent>
      </Card>
    </div>
  )
}

export function JobDetailPage() {
  const { jobId } = useParams()
  const jobQuery = useJobDetail(jobId)
  const job = jobQuery.data
  const streamState = useJobStream(jobId, {
    enabled: !isTerminalStatus(job?.status),
  })

  const translationsQuery = useJobTranslations(jobId)
  const audioQuery = useAudioReview(jobId, isAudioReadyStatus(job?.status))

  const retryMutation = useRetryJobMutation(jobId)
  const publishMutation = usePublishJobMutation(jobId)

  const units = translationsQuery.data ?? []
  const sentences = units.filter(
    (unit): unit is SentenceTranslationPayload => unit.unit_kind === "sentence",
  )
  const tables = units.filter(
    (unit): unit is TableTranslationPayload => unit.unit_kind === "table",
  )
  const sourceTextById = new Map(sentences.map((entry) => [entry.sentence_id, entry.source_text]))

  const headerActions = (
    <>
      {job?.status === "failed" && (
        <Button
          type="button"
          variant="outline"
          disabled={retryMutation.isPending}
          onClick={() =>
            retryMutation.mutate(undefined, {
              onSuccess: () => toast.success("已从安全检查点重新入队"),
              onError: (error) => toast.error(error.message),
            })
          }
        >
          <RotateCcw aria-hidden="true" />
          {retryMutation.isPending ? "重试中…" : "重试"}
        </Button>
      )}
      {job?.status === "review_required" && (
        <Button
          type="button"
          disabled={publishMutation.isPending}
          onClick={() =>
            publishMutation.mutate(undefined, {
              onSuccess: (result) => toast.success(`已发布制品 ${result.package_id}`),
              onError: (error) => toast.error(error.message),
            })
          }
        >
          <Rocket aria-hidden="true" />
          {publishMutation.isPending ? "发布中…" : "构建并发布"}
        </Button>
      )}
    </>
  )

  if (jobQuery.isPending) {
    return (
      <div className="space-y-6" aria-busy="true">
        <PageHeader
          title="任务详情"
          breadcrumbs={[{ label: "工作台", to: "/" }, { label: "任务", to: "/jobs" }, { label: "…" }]}
        />
        <Skeleton className="h-10 w-full" />
        <Skeleton className="h-40 w-full" />
        <Skeleton className="h-64 w-full" />
      </div>
    )
  }

  if (jobQuery.isError || !job) {
    return (
      <div className="space-y-6">
        <PageHeader
          title="任务详情"
          breadcrumbs={[{ label: "工作台", to: "/" }, { label: "任务", to: "/jobs" }, { label: "加载失败" }]}
        />
        <div
          role="alert"
          className="rounded-lg border border-destructive/50 bg-destructive/10 p-4 text-sm text-destructive"
        >
          任务加载失败：
          {jobQuery.error instanceof Error ? jobQuery.error.message : "未知错误"}
        </div>
        <Link to="/jobs" className="text-sm text-primary hover:underline">
          返回任务列表
        </Link>
      </div>
    )
  }

  return (
    <div className="space-y-6">
      <PageHeader
        title={`任务 ${job.job_id.slice(0, 8)}`}
        breadcrumbs={[
          { label: "工作台", to: "/" },
          { label: "任务", to: "/jobs" },
          { label: job.job_id.slice(0, 8) },
        ]}
        actions={headerActions}
      />

      <JobProgressPanel job={job} streamState={streamState} />

      <div className="flex flex-wrap items-center gap-2 text-sm text-muted-foreground">
        <JobStatusBadge status={job.status} />
        <span>尝试 {job.attempts} 次</span>
        <span>·</span>
        <span>创建于 {formatDateTime(job.created_at)}</span>
        {job.started_at && (
          <>
            <span>·</span>
            <span>开始于 {formatDateTime(job.started_at)}</span>
          </>
        )}
        {job.finished_at && (
          <>
            <span>·</span>
            <span>结束于 {formatDateTime(job.finished_at)}</span>
          </>
        )}
      </div>

      <DetailGrid job={job} />

      {job.status === "failed" && (
        <Card className="border-destructive/50">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-destructive">
              <TriangleAlert aria-hidden="true" className="size-4" />
              任务失败
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <KeyValues
              items={[
                { label: "错误码", value: job.error?.code ?? "—", mono: true },
                { label: "消息", value: job.error?.message ?? "—" },
              ]}
            />
            <Button
              type="button"
              variant="outline"
              disabled={retryMutation.isPending}
              onClick={() =>
                retryMutation.mutate(undefined, {
                  onSuccess: () => toast.success("已从安全检查点重新入队"),
                  onError: (error) => toast.error(error.message),
                })
              }
            >
              <RotateCcw aria-hidden="true" />
              从安全检查点重试
            </Button>
          </CardContent>
        </Card>
      )}

      {job.status === "succeeded" && (
        <Card className="border-emerald-500/50">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-emerald-600 dark:text-emerald-400">
              <CircleCheck aria-hidden="true" className="size-4" />
              发布完成
            </CardTitle>
          </CardHeader>
          <CardContent className="text-sm text-muted-foreground">
            当前制品已进入局域网只读目录。
          </CardContent>
        </Card>
      )}

      <TranslationReviewPanel
        jobId={job.job_id}
        sentences={sentences}
        tables={tables}
        editable={job.status === "review_required"}
        loading={translationsQuery.isPending}
      />

      {audioQuery.data && (
        <AudioReviewPanel review={audioQuery.data} sourceTextById={sourceTextById} />
      )}
      {audioQuery.isError && (
        <p className="text-sm text-muted-foreground">音频审阅不可用：音频尚未就绪。</p>
      )}
    </div>
  )
}
