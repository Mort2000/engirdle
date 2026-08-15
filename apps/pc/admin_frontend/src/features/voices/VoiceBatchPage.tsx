/**
 * 批次候选试听与确认（设计 §5.1 /voices/batches/:id，对应旧
 * voice_batch.html）：
 * - 候选逐个试听（原生 audio + 既有批次音频端点）；
 * - 确认激活：POST /api/voices/batches/{id}/confirm/{index}，
 *   可选“追加到既有配置 ID”（为该配置创建新修订，留空则新建配置），
 *   确认后回声音总览；
 * - 拒绝交互：放弃该批次（不确认，返回总览；批次保留可再试听）。
 */

import { useState } from "react"
import { Link, useNavigate, useParams } from "react-router"
import { toast } from "sonner"

import { useAnchorBatch, useConfirmCandidateMutation } from "@/api/hooks/voices"
import { anchorCandidateAudioUrl } from "@/api/voices"
import { PageHeader } from "@/components/layout/PageHeader"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Skeleton } from "@/components/ui/skeleton"
import { shortenHash } from "@/lib/hashes"
import { formatDateTime } from "@/lib/time"

function CandidateRow({
  batchId,
  candidate,
  onConfirm,
  confirming,
}: {
  batchId: string
  candidate: {
    candidate_index: number
    seed: number
    sha256: string
    duration_ms: number
    sample_rate_hz: number
  }
  onConfirm: (candidateIndex: number, voiceProfileId: string | null) => void
  confirming: boolean
}) {
  const [profileId, setProfileId] = useState("")
  const ordinal = candidate.candidate_index + 1

  return (
    <div className="rounded-lg border p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="font-medium">候选 {ordinal}</p>
          <p className="mt-0.5 text-xs text-muted-foreground">
            seed {candidate.seed} · {candidate.duration_ms} ms ·{" "}
            {candidate.sample_rate_hz} Hz ·{" "}
            <span className="font-mono">
              {shortenHash(candidate.sha256, 12)}
            </span>
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Input
            value={profileId}
            onChange={(event) => setProfileId(event.target.value)}
            placeholder="追加到既有配置 ID（可留空）"
            aria-label={`追加到既有配置 ID（候选 ${ordinal}）`}
            className="h-8 w-56 text-xs"
          />
          <Button
            size="sm"
            disabled={confirming}
            aria-label={`确认候选 ${ordinal}`}
            onClick={() =>
              onConfirm(candidate.candidate_index, profileId.trim() || null)
            }
          >
            {confirming ? "确认中…" : "确认此候选"}
          </Button>
        </div>
      </div>
      <audio
        controls
        preload="metadata"
        src={anchorCandidateAudioUrl(batchId, candidate.candidate_index)}
        aria-label={`候选 ${ordinal} 音频`}
        className="mt-3 w-full"
      />
    </div>
  )
}

export function VoiceBatchPage() {
  const { batchId } = useParams()
  const navigate = useNavigate()
  const batchQuery = useAnchorBatch(batchId)
  const confirmMutation = useConfirmCandidateMutation(batchId ?? "")

  const batch = batchQuery.data

  const onConfirm = async (candidateIndex: number, voiceProfileId: string | null) => {
    try {
      const profile = await confirmMutation.mutateAsync({
        candidateIndex,
        voiceProfileId,
      })
      toast.success(
        `已确认 ${profile.voice_profile_id.slice(0, 8)}@${profile.revision} 并设为当前激活`,
      )
      // 确认后回声音总览（与旧页面 redirect 语义一致）。
      navigate("/voices")
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "确认失败，请重试",
      )
    }
  }

  return (
    <div className="space-y-6">
      <PageHeader
        title="试听并确认锚点"
        breadcrumbs={[
          { label: "工作台", to: "/" },
          { label: "声音配置", to: "/voices" },
          { label: batchId ? `批次 ${batchId.slice(0, 8)}` : "批次…" },
        ]}
        actions={
          <Button variant="outline" onClick={() => navigate("/voices")}>
            放弃该批次
          </Button>
        }
      />

      {batchQuery.isPending ? (
        <div className="space-y-3" aria-busy="true" aria-label="批次加载中">
          <Skeleton className="h-20 w-full" />
          <Skeleton className="h-32 w-full" />
        </div>
      ) : batchQuery.isError ? (
        <div
          role="alert"
          className="rounded-lg border border-destructive/50 bg-destructive/10 p-4 text-sm text-destructive"
        >
          批次加载失败：
          {batchQuery.error instanceof Error
            ? batchQuery.error.message
            : "未知错误"}
        </div>
      ) : batch ? (
        <>
          <Card>
            <CardHeader>
              <CardTitle>批次信息</CardTitle>
              <CardDescription>
                {batch.speaker} · {formatDateTime(batch.created_at)}
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-1 text-sm text-muted-foreground">
              <p>
                朗读文本：<span className="text-foreground">{batch.anchor_text}</span>
              </p>
              {batch.instruct && (
                <p>
                  instruct：<span className="text-foreground">{batch.instruct}</span>
                </p>
              )}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>候选</CardTitle>
              <CardDescription>
                {batch.candidates.length} 个（每个候选使用不同 seed）
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              {[...batch.candidates]
                .sort((a, b) => a.candidate_index - b.candidate_index)
                .map((candidate) => (
                  <CandidateRow
                    key={candidate.candidate_index}
                    batchId={batch.batch_id}
                    candidate={candidate}
                    onConfirm={(index, profileId) =>
                      void onConfirm(index, profileId)
                    }
                    confirming={confirmMutation.isPending}
                  />
                ))}

              <Alert>
                <AlertTitle>冻结规则</AlertTitle>
                <AlertDescription>
                  确认会把候选 WAV 复制为不可变锚点并记录哈希；“追加到既有
                  配置 ID”会为该配置创建新修订，留空则创建全新配置。确认后
                  自动设为当前激活配置。
                </AlertDescription>
              </Alert>

              <div className="flex items-center gap-3">
                <Button asChild variant="ghost">
                  <Link to="/voices">返回声音配置</Link>
                </Button>
              </div>
            </CardContent>
          </Card>
        </>
      ) : null}
    </div>
  )
}
