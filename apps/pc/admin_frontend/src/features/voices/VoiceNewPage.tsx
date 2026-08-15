/**
 * 新建锚点候选（设计 §5.1 /voices/new，对应旧 voice_new.html）：
 * speaker 选择 + 锚点朗读文本 + instruct 风格 + 起始 seed + 候选数，
 * 提交 POST /api/voices/batches 后跳转批次试听页。
 *
 * 校验约束与后端 CreateAnchorBatchRequest 同构（anchor ≤2000、
 * instruct ≤1000、seed ≥0、count 1–10）。生成会加载 CustomVoice
 * 检查点，通常需要几十秒，提交按钮在 pending 期间明示等待。
 */

import { useEffect, useMemo } from "react"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { Link, useNavigate } from "react-router"
import { toast } from "sonner"
import { z } from "zod"

import { useCreateAnchorBatchMutation, useVoiceSpeakers } from "@/api/hooks/voices"
import { PageHeader } from "@/components/layout/PageHeader"
import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import {
  Form,
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from "@/components/ui/form"
import { Input } from "@/components/ui/input"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import { Skeleton } from "@/components/ui/skeleton"
import { Textarea } from "@/components/ui/textarea"

/** 与后端锚点默认文本保持一致（API 未单独暴露默认值）。 */
const DEFAULT_ANCHOR_TEXT =
  "Every article deserves a clear voice. When the narration flows naturally, " +
  "listening becomes effortless."

/** 与后端配置默认值一致（speech_anchor_candidates = 3）。 */
const DEFAULT_CANDIDATE_COUNT = 3

const voiceFormSchema = z.object({
  speaker: z.string().min(1, "请选择英文 Speaker"),
  anchor_text: z
    .string()
    .trim()
    .min(1, "请输入锚点朗读文本")
    .max(2000, "锚点朗读文本最长 2000 字符"),
  instruct: z.string().max(1000, "instruct 最长 1000 字符"),
  seed: z
    .number({ message: "起始 seed 须为不小于 0 的整数" })
    .int("起始 seed 须为整数")
    .min(0, "起始 seed 须不小于 0"),
  count: z
    .number({ message: "候选数量须为 1–10 的整数" })
    .int("候选数量须为整数")
    .min(1, "候选数量至少 1 个")
    .max(10, "候选数量最多 10 个"),
})

export type VoiceFormValues = z.infer<typeof voiceFormSchema>

export function VoiceNewPage() {
  const navigate = useNavigate()
  const speakersQuery = useVoiceSpeakers()
  const createMutation = useCreateAnchorBatchMutation()
  // 稳定空数组标识，避免 useEffect 依赖每 render 变化。
  const speakers = useMemo(() => speakersQuery.data ?? [], [speakersQuery.data])

  const form = useForm<VoiceFormValues>({
    resolver: zodResolver(voiceFormSchema),
    defaultValues: {
      speaker: "",
      anchor_text: DEFAULT_ANCHOR_TEXT,
      instruct: "",
      seed: 0,
      count: DEFAULT_CANDIDATE_COUNT,
    },
  })

  // Speaker 选项加载完成后默认选中第一个（与旧页面 select 首选项一致）。
  useEffect(() => {
    const firstSpeaker = speakers.at(0)
    if (firstSpeaker && form.getValues("speaker") === "") {
      form.setValue("speaker", firstSpeaker.name, { shouldValidate: true })
    }
  }, [speakers, form])

  const onSubmit = form.handleSubmit(async (values) => {
    try {
      const batch = await createMutation.mutateAsync({
        speaker: values.speaker,
        anchor_text: values.anchor_text,
        instruct: values.instruct.trim(),
        seed: values.seed,
        count: values.count,
      })
      toast.success(`已生成 ${batch.candidates.length} 个候选，请试听确认`)
      navigate(`/voices/batches/${batch.batch_id}`)
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "候选生成失败，请重试",
      )
    }
  })

  const submitting = createMutation.isPending

  return (
    <div className="space-y-6">
      <PageHeader
        title="新建锚点候选"
        breadcrumbs={[
          { label: "工作台", to: "/" },
          { label: "声音配置", to: "/voices" },
          { label: "新建候选" },
        ]}
      />
      <Card>
        <CardHeader>
          <CardTitle>锚点候选参数</CardTitle>
          <CardDescription>
            每个候选使用不同 seed 生成；生成会加载 CustomVoice 检查点，
            通常需要几十秒，期间请保持页面打开。
          </CardDescription>
        </CardHeader>
        <CardContent>
          {speakersQuery.isPending ? (
            <div className="space-y-3" aria-busy="true" aria-label="Speaker 列表加载中">
              <Skeleton className="h-9 w-full" />
              <Skeleton className="h-28 w-full" />
            </div>
          ) : speakersQuery.isError ? (
            <div
              role="alert"
              className="rounded-lg border border-destructive/50 bg-destructive/10 p-4 text-sm text-destructive"
            >
              Speaker 列表加载失败：
              {speakersQuery.error instanceof Error
                ? speakersQuery.error.message
                : "未知错误"}
            </div>
          ) : (
            <Form {...form}>
              <form onSubmit={onSubmit} className="space-y-4" noValidate>
                <FormField
                  control={form.control}
                  name="speaker"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>英文 Speaker</FormLabel>
                      <Select onValueChange={field.onChange} value={field.value}>
                        <FormControl>
                          <SelectTrigger
                            className="w-full"
                            aria-label="英文 Speaker"
                          >
                            <SelectValue placeholder="选择 Speaker" />
                          </SelectTrigger>
                        </FormControl>
                        <SelectContent>
                          {speakers.map((speaker) => (
                            <SelectItem key={speaker.name} value={speaker.name}>
                              {speaker.name} — {speaker.description}
                            </SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                      <FormMessage />
                    </FormItem>
                  )}
                />

                <FormField
                  control={form.control}
                  name="anchor_text"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>锚点朗读文本（英文）</FormLabel>
                      <FormControl>
                        <Textarea
                          {...field}
                          rows={4}
                          placeholder="Anchor text must match the frozen audio verbatim."
                        />
                      </FormControl>
                      <FormDescription>
                        确认后必须与锚点音频逐字一致。
                      </FormDescription>
                      <FormMessage />
                    </FormItem>
                  )}
                />

                <FormField
                  control={form.control}
                  name="instruct"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>风格 instruct（可选，英文）</FormLabel>
                      <FormControl>
                        <Textarea
                          {...field}
                          rows={2}
                          placeholder="例如：Calm, steady narration at a moderate pace."
                        />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />

                <div className="grid gap-4 sm:grid-cols-2">
                  <FormField
                    control={form.control}
                    name="seed"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>起始 seed</FormLabel>
                        <FormControl>
                          <Input
                            value={Number.isFinite(field.value) ? field.value : ""}
                            onChange={(event) =>
                              field.onChange(event.target.valueAsNumber)
                            }
                            type="number"
                            min={0}
                            step={1}
                          />
                        </FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                  <FormField
                    control={form.control}
                    name="count"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel>候选数量</FormLabel>
                        <FormControl>
                          <Input
                            value={Number.isFinite(field.value) ? field.value : ""}
                            onChange={(event) =>
                              field.onChange(event.target.valueAsNumber)
                            }
                            type="number"
                            min={1}
                            max={10}
                            step={1}
                          />
                        </FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                </div>

                <div className="flex items-center gap-3 pt-2">
                  <Button type="submit" disabled={submitting}>
                    {submitting ? "生成中…（通常需要几十秒）" : "加载模型并生成候选"}
                  </Button>
                  <Button asChild variant="ghost" disabled={submitting}>
                    <Link to="/voices">取消</Link>
                  </Button>
                </div>
              </form>
            </Form>
          )}
        </CardContent>
      </Card>
    </div>
  )
}
