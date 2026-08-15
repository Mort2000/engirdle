/**
 * 声音配置域 API 载荷类型与请求函数（与 api/jobs.ts 同一约定）。
 *
 * 形状对齐 app.py `_voice_profile_payload` / `_anchor_batch_payload` 与
 * `CreateAnchorBatchRequest` / `ConfirmVoiceProfileRequest` 请求模型。
 */

import { apiFetch } from "@/api/client"

export interface VoiceSpeakerPayload {
  name: string
  description: string
}

/** 已确认的不可变声音配置修订（is_active 标记当前激活）。 */
export interface VoiceProfilePayload {
  voice_profile_id: string
  revision: number
  speaker: string
  instruct: string
  anchor_text: string
  anchor_sha256: string
  sample_rate_hz: number
  duration_ms: number
  seed: number
  generation_params: string
  custom_voice_model: string
  model_fingerprint: string
  source_batch_id: string
  is_active: boolean
  confirmed_at: string
}

/** 锚点候选批次内的单个候选（audio 由既有批次音频端点提供）。 */
export interface AnchorCandidatePayload {
  candidate_index: number
  seed: number
  sha256: string
  duration_ms: number
  sample_rate_hz: number
}

export interface AnchorBatchPayload {
  batch_id: string
  speaker: string
  instruct: string
  anchor_text: string
  seed: number
  custom_voice_model: string
  model_fingerprint: string
  created_at: string
  candidates: AnchorCandidatePayload[]
}

export interface CreateAnchorBatchInput {
  speaker: string
  anchor_text: string
  instruct?: string
  seed?: number
  count?: number
}

/** 激活锚点音频端点（audio 元素 src 直用）。 */
export function voiceProfileAudioUrl(
  voiceProfileId: string,
  revision: number,
): string {
  return `/api/voices/profiles/${voiceProfileId}/${revision}/audio`
}

/** 批次候选音频端点（audio 元素 src 直用）。 */
export function anchorCandidateAudioUrl(
  batchId: string,
  candidateIndex: number,
): string {
  return `/api/voices/batches/${batchId}/audio/${candidateIndex}`
}

export function listVoiceSpeakers(): Promise<VoiceSpeakerPayload[]> {
  return apiFetch<VoiceSpeakerPayload[]>("/api/voices/speakers")
}

export function listVoiceProfiles(): Promise<VoiceProfilePayload[]> {
  return apiFetch<VoiceProfilePayload[]>("/api/voices/profiles")
}

export function listAnchorBatches(): Promise<AnchorBatchPayload[]> {
  return apiFetch<AnchorBatchPayload[]>("/api/voices/batches")
}

export function getAnchorBatch(batchId: string): Promise<AnchorBatchPayload> {
  return apiFetch<AnchorBatchPayload>(`/api/voices/batches/${batchId}`)
}

/** 生成锚点候选（会加载 CustomVoice 检查点，通常需要几十秒）。 */
export function createAnchorBatch(
  input: CreateAnchorBatchInput,
): Promise<AnchorBatchPayload> {
  return apiFetch<AnchorBatchPayload>("/api/voices/batches", {
    method: "POST",
    body: JSON.stringify(input),
  })
}

/** 确认候选并冻结为不可变修订；确认后自动设为当前激活配置。 */
export function confirmAnchorCandidate(
  batchId: string,
  candidateIndex: number,
  voiceProfileId: string | null,
): Promise<VoiceProfilePayload> {
  return apiFetch<VoiceProfilePayload>(
    `/api/voices/batches/${batchId}/confirm/${candidateIndex}`,
    {
      method: "POST",
      body: JSON.stringify({ voice_profile_id: voiceProfileId }),
    },
  )
}

/** 切换当前激活配置（生产任务始终使用激活配置）。 */
export function activateVoiceProfile(
  voiceProfileId: string,
  revision: number,
): Promise<VoiceProfilePayload> {
  return apiFetch<VoiceProfilePayload>(
    `/api/voices/profiles/${voiceProfileId}/${revision}/activate`,
    { method: "POST" },
  )
}
