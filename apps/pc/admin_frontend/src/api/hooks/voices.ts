/**
 * 声音配置域 TanStack Query hooks。
 *
 * 查询键按 ["voices", ...] 分层；候选确认/激活切换成功后失效整个
 * voices 前缀（总览的激活状态与修订历史随之刷新）。
 */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"

import {
  activateVoiceProfile,
  confirmAnchorCandidate,
  createAnchorBatch,
  getAnchorBatch,
  listAnchorBatches,
  listVoiceProfiles,
  listVoiceSpeakers,
  type CreateAnchorBatchInput,
} from "@/api/voices"

export const voicesKeys = {
  root: ["voices"] as const,
  speakers: () => [...voicesKeys.root, "speakers"] as const,
  profiles: () => [...voicesKeys.root, "profiles"] as const,
  batches: () => [...voicesKeys.root, "batches"] as const,
  batch: (batchId: string) => [...voicesKeys.root, "batch", batchId] as const,
}

/** 英文 Speaker 选项（/voices/new 表单）。 */
export function useVoiceSpeakers() {
  return useQuery({
    queryKey: voicesKeys.speakers(),
    queryFn: listVoiceSpeakers,
  })
}

/** 已确认配置修订（含 is_active；总览页派生激活配置与修订历史）。 */
export function useVoiceProfiles() {
  return useQuery({
    queryKey: voicesKeys.profiles(),
    queryFn: listVoiceProfiles,
  })
}

export function useAnchorBatches() {
  return useQuery({
    queryKey: voicesKeys.batches(),
    queryFn: listAnchorBatches,
  })
}

/** 批次详情（候选试听页）。 */
export function useAnchorBatch(batchId: string | undefined) {
  return useQuery({
    queryKey: voicesKeys.batch(batchId ?? ""),
    queryFn: () => getAnchorBatch(batchId as string),
    enabled: batchId !== undefined && batchId.length > 0,
  })
}

/** 生成候选批次；成功后由页面跳转批次页（不做缓存失效——批次为新增）。 */
export function useCreateAnchorBatchMutation() {
  return useMutation({
    mutationFn: (input: CreateAnchorBatchInput) => createAnchorBatch(input),
  })
}

/** 确认候选：确认后自动激活，失效 profiles/batches 让总览回填。 */
export function useConfirmCandidateMutation(batchId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: { candidateIndex: number; voiceProfileId: string | null }) =>
      confirmAnchorCandidate(batchId, input.candidateIndex, input.voiceProfileId),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: voicesKeys.root })
    },
  })
}

/** 切换激活修订。 */
export function useActivateProfileMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: { voiceProfileId: string; revision: number }) =>
      activateVoiceProfile(input.voiceProfileId, input.revision),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: voicesKeys.root })
    },
  })
}
