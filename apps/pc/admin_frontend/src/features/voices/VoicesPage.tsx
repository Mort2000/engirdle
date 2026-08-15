/**
 * 声音配置总览（设计 §5.1 /voices，对应旧 voices.html）：
 * - 当前激活配置卡片（锚点信息 + 锚点音频试听）；
 * - 修订历史（全部不可变修订，可切换激活）；
 * - 候选批次列表（链接批次试听页）；
 * - 无配置空态引导至 /voices/new。
 *
 * 生产任务始终使用当前激活配置；激活切换走既有 activate 端点。
 */

import { Link } from "react-router"
import { toast } from "sonner"

import {
  useActivateProfileMutation,
  useAnchorBatches,
  useVoiceProfiles,
} from "@/api/hooks/voices"
import {
  voiceProfileAudioUrl,
  type VoiceProfilePayload,
} from "@/api/voices"
import { KeyValues } from "@/components/KeyValues"
import { PageHeader } from "@/components/layout/PageHeader"
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
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { shortenHash } from "@/lib/hashes"
import { formatDateTime } from "@/lib/time"

function ProfilesSkeleton() {
  return (
    <div className="space-y-4" aria-busy="true" aria-label="声音配置加载中">
      <Skeleton className="h-48 w-full" />
      <Skeleton className="h-40 w-full" />
    </div>
  )
}

function ActiveProfileCard({
  activeProfile,
}: {
  activeProfile: VoiceProfilePayload | undefined
}) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>当前激活配置</CardTitle>
        <CardDescription>
          生产任务合成语音时使用的不可变锚点配置。
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {activeProfile ? (
          <>
            <KeyValues
              items={[
                {
                  label: "配置",
                  value: `${activeProfile.voice_profile_id.slice(0, 8)}@${activeProfile.revision}`,
                  mono: true,
                },
                { label: "Speaker", value: activeProfile.speaker },
                {
                  label: "instruct",
                  value: activeProfile.instruct || "—",
                },
                { label: "朗读文本", value: activeProfile.anchor_text },
                { label: "seed", value: String(activeProfile.seed) },
                {
                  label: "锚点时长",
                  value: `${activeProfile.duration_ms} ms`,
                },
                {
                  label: "采样率",
                  value: `${activeProfile.sample_rate_hz} Hz`,
                },
                {
                  label: "锚点哈希",
                  value: shortenHash(activeProfile.anchor_sha256, 12),
                  mono: true,
                },
                {
                  label: "确认时间",
                  value: formatDateTime(activeProfile.confirmed_at),
                },
              ]}
            />
            <audio
              controls
              preload="metadata"
              src={voiceProfileAudioUrl(
                activeProfile.voice_profile_id,
                activeProfile.revision,
              )}
              aria-label="激活配置锚点音频"
              className="w-full"
            />
          </>
        ) : (
          <div className="rounded-lg border border-dashed p-6 text-center">
            <p className="font-medium">还没有已确认的声音配置</p>
            <p className="mt-1 text-sm text-muted-foreground">
              新建锚点候选并试听确认后，生产任务才能合成语音。
            </p>
            <Button asChild className="mt-4">
              <Link to="/voices/new">新建锚点候选</Link>
            </Button>
          </div>
        )}
      </CardContent>
    </Card>
  )
}

function RevisionHistoryCard({
  profiles,
}: {
  profiles: VoiceProfilePayload[]
}) {
  const activateMutation = useActivateProfileMutation()

  const onActivate = async (profile: VoiceProfilePayload) => {
    try {
      await activateMutation.mutateAsync({
        voiceProfileId: profile.voice_profile_id,
        revision: profile.revision,
      })
      toast.success(
        `已激活 ${profile.voice_profile_id.slice(0, 8)}@${profile.revision}`,
      )
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "激活失败，请重试",
      )
    }
  }

  // 修订历史按确认时间倒序（最新修订在前）。
  const ordered = [...profiles].sort((a, b) =>
    b.confirmed_at.localeCompare(a.confirmed_at),
  )

  return (
    <Card>
      <CardHeader>
        <CardTitle>修订历史</CardTitle>
        <CardDescription>
          {profiles.length} 个不可变修订；确认后的锚点 WAV 与哈希被冻结。
        </CardDescription>
      </CardHeader>
      <CardContent>
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>配置</TableHead>
              <TableHead>Speaker</TableHead>
              <TableHead>seed</TableHead>
              <TableHead>确认时间</TableHead>
              <TableHead className="w-28">状态</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {ordered.map((profile) => (
              <TableRow key={`${profile.voice_profile_id}-${profile.revision}`}>
                <TableCell className="font-mono text-[13px]">
                  {profile.voice_profile_id.slice(0, 8)}@{profile.revision}
                </TableCell>
                <TableCell>{profile.speaker}</TableCell>
                <TableCell className="tabular-nums">{profile.seed}</TableCell>
                <TableCell className="text-muted-foreground">
                  {formatDateTime(profile.confirmed_at)}
                </TableCell>
                <TableCell>
                  {profile.is_active ? (
                    <Badge className="bg-emerald-500/15 text-emerald-600 dark:text-emerald-400">
                      当前激活
                    </Badge>
                  ) : (
                    <Button
                      variant="outline"
                      size="xs"
                      disabled={activateMutation.isPending}
                      onClick={() => void onActivate(profile)}
                    >
                      设为激活
                    </Button>
                  )}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </CardContent>
    </Card>
  )
}

function BatchesCard({
  batches,
}: {
  batches: { batch_id: string; speaker: string; created_at: string; anchor_text: string; candidateCount: number }[]
}) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>候选批次</CardTitle>
        <CardDescription>{batches.length} 批（未确认的候选可继续试听）</CardDescription>
      </CardHeader>
      <CardContent className="space-y-2">
        {batches.length === 0 ? (
          <p className="px-1 py-6 text-sm text-muted-foreground">
            还没有候选批次。
          </p>
        ) : (
          batches.map((batch) => (
            <Link
              key={batch.batch_id}
              to={`/voices/batches/${batch.batch_id}`}
              className="flex items-center gap-3 rounded-lg border px-3 py-2.5 transition-colors hover:bg-accent/50"
            >
              <div className="min-w-0 flex-1">
                <p className="truncate font-medium">
                  {batch.speaker} · {batch.candidateCount} 个候选
                </p>
                <p className="mt-0.5 truncate text-xs text-muted-foreground">
                  {formatDateTime(batch.created_at)} · {batch.anchor_text}
                </p>
              </div>
              <span className="text-sm text-muted-foreground">试听 →</span>
            </Link>
          ))
        )}
      </CardContent>
    </Card>
  )
}

export function VoicesPage() {
  const profilesQuery = useVoiceProfiles()
  const batchesQuery = useAnchorBatches()

  const profiles = profilesQuery.data ?? []
  const batches = batchesQuery.data ?? []
  const activeProfile = profiles.find((profile) => profile.is_active)
  const pending = profilesQuery.isPending || batchesQuery.isPending
  const error = profilesQuery.error ?? batchesQuery.error

  return (
    <div className="space-y-6">
      <PageHeader
        title="声音配置"
        breadcrumbs={[{ label: "工作台", to: "/" }, { label: "声音配置" }]}
        actions={
          <Button asChild>
            <Link to="/voices/new">新建锚点候选</Link>
          </Button>
        }
      />

      {pending ? (
        <ProfilesSkeleton />
      ) : error ? (
        <div
          role="alert"
          className="rounded-lg border border-destructive/50 bg-destructive/10 p-4 text-sm text-destructive"
        >
          声音配置加载失败：
          {error instanceof Error ? error.message : "未知错误"}
        </div>
      ) : (
        <>
          <ActiveProfileCard activeProfile={activeProfile} />
          {profiles.length > 0 && <RevisionHistoryCard profiles={profiles} />}
          <BatchesCard
            batches={batches.map((batch) => ({
              batch_id: batch.batch_id,
              speaker: batch.speaker,
              created_at: batch.created_at,
              anchor_text: batch.anchor_text,
              candidateCount: batch.candidates.length,
            }))}
          />
        </>
      )}
    </div>
  )
}
