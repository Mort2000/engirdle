/**
 * 音频审阅面板（设计 §6.4/§8.4）：原生 `<audio>` 播放器 + 句级播放按钮
 * （区间跳转，沿用旧页交互语义）+ 完整性检查计数。
 *
 * 句级原文由译文查询的 source_text 按 sentence_id 关联（音频端点只含
 * 时间轴，原页面为服务端拼装，SPA 侧改为前端 join）。
 */

import { useEffect, useRef } from "react"

import type { AudioReviewPayload } from "@/api/jobs"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"

function checkTone(count: number): string {
  return count > 0
    ? "bg-amber-500/15 text-amber-600 dark:text-amber-400"
    : "bg-secondary text-secondary-foreground"
}

export function AudioReviewPanel({
  review,
  sourceTextById,
}: {
  review: AudioReviewPayload
  sourceTextById: ReadonlyMap<string, string>
}) {
  const audioRef = useRef<HTMLAudioElement>(null)
  const stopAtRef = useRef<number | null>(null)

  useEffect(() => {
    const audio = audioRef.current
    if (!audio) {
      return
    }
    const onTimeUpdate = () => {
      const stopAt = stopAtRef.current
      if (stopAt !== null && audio.currentTime >= stopAt) {
        audio.pause()
        stopAtRef.current = null
      }
    }
    audio.addEventListener("timeupdate", onTimeUpdate)
    return () => audio.removeEventListener("timeupdate", onTimeUpdate)
  }, [])

  const playRange = (startMs: number, endMs: number) => {
    const audio = audioRef.current
    if (!audio) {
      return
    }
    audio.currentTime = startMs / 1000
    stopAtRef.current = endMs / 1000
    try {
      // jsdom/部分环境 play() 不返回 Promise 或未实现，容错处理。
      const playback: unknown = audio.play()
      if (playback instanceof Promise) {
        playback.catch(() => {
          // 播放被浏览器策略拒绝时保持静默，用户可直接操作原生控件。
        })
      }
    } catch {
      // 未实现媒体播放的环境（如测试）忽略。
    }
  }

  const checks = review.checks
  const checkItems = [
    { label: "缺失", count: checks.missing_sentence_ids.length },
    { label: "零时长", count: checks.zero_duration_sentence_ids.length },
    { label: "异常时长", count: checks.abnormal_duration_sentence_ids.length },
  ]

  return (
    <Card>
      <CardHeader>
        <CardTitle>音频逐句审核</CardTitle>
        <CardDescription>
          {review.sentences.length} 句 ·{" "}
          {(review.duration_ms / 1000).toFixed(1)} 秒 ·{" "}
          {review.sample_rate_hz} Hz · {review.encoder_version}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        <audio
          ref={audioRef}
          controls
          preload="metadata"
          src={review.url}
          className="w-full"
          data-testid="review-audio"
        />
        <div className="flex flex-wrap gap-2 text-xs" aria-label="音频完整性校验">
          {checkItems.map((item) => (
            <span
              key={item.label}
              className={`inline-flex items-center rounded-full px-2 py-0.5 ${checkTone(item.count)}`}
            >
              {item.label} {item.count}
            </span>
          ))}
        </div>
        <ol className="space-y-2">
          {review.sentences.map((timing) => (
            <li
              key={timing.sentence_id}
              className="flex flex-wrap items-center gap-x-3 gap-y-1"
            >
              <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={() => playRange(timing.start_ms, timing.end_ms)}
              >
                播放此句
              </Button>
              <span className="min-w-0 flex-1 text-sm">
                {sourceTextById.get(timing.sentence_id) ?? timing.sentence_id}
              </span>
              <small className="font-mono text-xs text-muted-foreground">
                {timing.start_ms}–{timing.end_ms} ms
              </small>
            </li>
          ))}
        </ol>
      </CardContent>
    </Card>
  )
}
