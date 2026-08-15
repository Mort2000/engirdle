/** 声音配置域测试夹具：与 app.py 载荷形状一致的最小可裁剪样本。 */

import type {
  AnchorBatchPayload,
  VoiceProfilePayload,
  VoiceSpeakerPayload,
} from "@/api/voices"

export function makeSpeaker(
  overrides: Partial<VoiceSpeakerPayload> = {},
): VoiceSpeakerPayload {
  return {
    name: "Ethan",
    description: "Warm male narration",
    ...overrides,
  }
}

export function makeVoiceProfile(
  overrides: Partial<VoiceProfilePayload> = {},
): VoiceProfilePayload {
  return {
    voice_profile_id: "vp-0001",
    revision: 1,
    speaker: "Ethan",
    instruct: "",
    anchor_text: "Every article deserves a clear voice.",
    anchor_sha256: "a".repeat(64),
    sample_rate_hz: 24_000,
    duration_ms: 4_200,
    seed: 7,
    generation_params: "{}",
    custom_voice_model: "custom-voice-v1",
    model_fingerprint: "fp-1",
    source_batch_id: "batch-0001",
    is_active: true,
    confirmed_at: "2026-08-15T08:00:00+00:00",
    ...overrides,
  }
}

export function makeAnchorBatch(
  overrides: Partial<AnchorBatchPayload> = {},
): AnchorBatchPayload {
  return {
    batch_id: "batch-0001",
    speaker: "Ethan",
    instruct: "",
    anchor_text: "Every article deserves a clear voice.",
    seed: 7,
    custom_voice_model: "custom-voice-v1",
    model_fingerprint: "fp-1",
    created_at: "2026-08-15T08:00:00+00:00",
    candidates: [
      {
        candidate_index: 0,
        seed: 7,
        sha256: "b".repeat(64),
        duration_ms: 4_100,
        sample_rate_hz: 24_000,
      },
      {
        candidate_index: 1,
        seed: 8,
        sha256: "c".repeat(64),
        duration_ms: 4_300,
        sample_rate_hz: 24_000,
      },
    ],
    ...overrides,
  }
}
