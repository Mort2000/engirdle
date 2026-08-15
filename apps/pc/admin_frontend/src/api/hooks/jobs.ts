/**
 * 任务域 TanStack Query hooks（设计 §5：api/hooks/）。
 *
 * 查询键按 ["jobs", ...] 分层，SSE/变更统一失效 ["jobs"] 前缀即可
 * 级联到详情、译文与音频查询（§8.4：事件驱动缓存失效）。
 */

import {
  keepPreviousData,
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query"

import {
  editSentenceTranslation,
  editTableTranslation,
  getAudioReview,
  getJob,
  getStructureReport,
  listJobs,
  listTranslations,
  publishJob,
  retryJob,
} from "@/api/jobs"

export const jobsKeys = {
  root: ["jobs"] as const,
  list: () => [...jobsKeys.root, "list"] as const,
  detail: (jobId: string) => [...jobsKeys.root, "detail", jobId] as const,
  translations: (jobId: string) =>
    [...jobsKeys.root, "translations", jobId] as const,
  audio: (jobId: string) => [...jobsKeys.root, "audio", jobId] as const,
}

/** 近期任务列表（§5.1 独立列表页；5s 轮询由调用方经 refetchInterval 决定）。 */
export function useJobsList(options?: { refetchInterval?: number }) {
  return useQuery({
    queryKey: jobsKeys.list(),
    queryFn: listJobs,
    placeholderData: keepPreviousData,
    refetchInterval: options?.refetchInterval,
  })
}

/** 任务详情；SSE 直写缓存，轮询仅作为断连降级（useJobStream）。 */
export function useJobDetail(jobId: string | undefined) {
  return useQuery({
    queryKey: jobsKeys.detail(jobId ?? ""),
    queryFn: () => getJob(jobId as string),
    enabled: jobId !== undefined && jobId.length > 0,
  })
}

/** 译文（句级 + 整表），随任务存在即可查询；编辑入口由页面按状态门控。 */
export function useJobTranslations(jobId: string | undefined) {
  return useQuery({
    queryKey: jobsKeys.translations(jobId ?? ""),
    queryFn: () => listTranslations(jobId as string),
    enabled: jobId !== undefined && jobId.length > 0,
  })
}

/** 音频审阅：仅音频就绪状态启用（后端 require_audio_ready 同语义）。 */
export function useAudioReview(
  jobId: string | undefined,
  audioReady: boolean,
) {
  return useQuery({
    queryKey: jobsKeys.audio(jobId ?? ""),
    queryFn: () => getAudioReview(jobId as string),
    enabled: audioReady && jobId !== undefined && jobId.length > 0,
  })
}

/** 处理计数来自结构报告端点（§8.5：替代原页面服务端拼装）。 */
export function useStructureReport(
  articleId: string | undefined,
  revision: number | undefined,
) {
  return useQuery({
    queryKey: ["articles", "structure-report", articleId, revision],
    queryFn: () => getStructureReport(articleId as string, revision as number),
    enabled:
      articleId !== undefined &&
      articleId.length > 0 &&
      revision !== undefined,
  })
}

export function useRetryJobMutation(jobId: string | undefined) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: () => retryJob(jobId as string),
    onSuccess: () => {
      // 详情重新拉取后状态回到 queued，SSE 流随之重建。
      void queryClient.invalidateQueries({ queryKey: jobsKeys.root })
    },
  })
}

export function usePublishJobMutation(jobId: string | undefined) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: () => publishJob(jobId as string),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: jobsKeys.root })
    },
  })
}

export function useEditSentenceTranslationMutation(jobId: string | undefined) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: { sentenceId: string; textZh: string }) =>
      editSentenceTranslation(jobId as string, input.sentenceId, input.textZh),
    onSuccess: () => {
      void queryClient.invalidateQueries({
        queryKey: jobsKeys.translations(jobId ?? ""),
      })
    },
  })
}

export function useEditTableTranslationMutation(jobId: string | undefined) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: {
      blockId: string
      cells: { cell_id: string; text_zh: string }[]
    }) => editTableTranslation(jobId as string, input.blockId, input.cells),
    onSuccess: () => {
      void queryClient.invalidateQueries({
        queryKey: jobsKeys.translations(jobId ?? ""),
      })
    },
  })
}
