/** 任务域测试夹具：与后端 app.py 载荷形状一致的最小可裁剪样本。 */

import type {
  AudioReviewPayload,
  JobDetailPayload,
  JobStatus,
  SentenceTranslationPayload,
  StructureReportPayload,
  TableTranslationPayload,
  TranslationUnitPayload,
} from "@/api/jobs"
import type { ProgressLike } from "@/lib/progress"

export function makeProgress(overrides: Partial<ProgressLike> = {}): ProgressLike {
  return {
    stage: "translation",
    stage_index: 1,
    percent: 0,
    done_units: null,
    total_units: null,
    indeterminate: true,
    ...overrides,
  }
}

export function makeJobDetail(
  overrides: Partial<JobDetailPayload> = {},
): JobDetailPayload {
  return {
    job_id: "job-0001",
    article_id: "art-0001",
    revision: 2,
    status: "review_required" as JobStatus,
    stage: "review",
    attempts: 1,
    translation_adapter: "stub",
    speech_adapter: "stub",
    config_snapshot: {
      pipeline_version: "1",
      segmenter: "default",
      translation: {
        adapter: "stub",
        provider: "stub",
        endpoint: "http://localhost/translate",
        model: "stub-model",
        thinking: "off",
        reasoning_effort: "none",
        prompt: "translate the article",
      },
      speech: {
        adapter: "stub",
        custom_voice_model: "",
        base_model: "stub-tts",
        generation: "{}",
        voice_profile: "vp-0001",
        anchor_sha256: "a".repeat(64),
      },
      audio_encoding: {
        codec: "aac-lc",
        bitrate_kbps: 64,
        loudness_target_lufs: -18,
        true_peak_dbfs: -3,
        loudness_range_lu: 11,
      },
    },
    created_at: "2026-08-15T08:00:00+00:00",
    started_at: "2026-08-15T08:00:05+00:00",
    heartbeat_at: "2026-08-15T08:01:00+00:00",
    finished_at: null,
    error: null,
    progress: makeProgress({
      stage: "review",
      stage_index: 4,
      percent: 97,
      done_units: null,
      total_units: null,
      indeterminate: false,
    }),
    ...overrides,
  }
}

export function makeSentenceTranslation(
  overrides: Partial<SentenceTranslationPayload> = {},
): SentenceTranslationPayload {
  return {
    unit_kind: "sentence",
    unit_id: "tu-0001",
    sentence_id: "sent-0001",
    source_text: "Hello world.",
    generated_text: "你好，世界。",
    edited_text: null,
    published_text: "你好，世界。",
    ...overrides,
  }
}

export function makeTableTranslation(
  overrides: Partial<TableTranslationPayload> = {},
): TableTranslationPayload {
  return {
    unit_kind: "table",
    unit_id: "blk-table-0001",
    cells: [
      {
        cell_id: "cell-0001",
        generated_text: "列 A",
        edited_text: null,
        published_text: "列 A",
      },
      {
        cell_id: "cell-0002",
        generated_text: "列 B",
        edited_text: null,
        published_text: "列 B",
      },
    ],
    ...overrides,
  }
}

export function makeTranslationUnits(): TranslationUnitPayload[] {
  return [
    makeSentenceTranslation(),
    makeSentenceTranslation({
      sentence_id: "sent-0002",
      unit_id: "tu-0001",
      source_text: "Second sentence.",
      generated_text: "第二句。",
      published_text: "第二句。",
    }),
    makeTableTranslation(),
  ]
}

export function makeAudioReview(
  overrides: Partial<AudioReviewPayload> = {},
): AudioReviewPayload {
  return {
    url: "/api/jobs/job-0001/audio/file",
    duration_ms: 12_500,
    sample_rate_hz: 24_000,
    channels: 1,
    encoder_version: "enc-1",
    sentences: [
      { sentence_id: "sent-0001", start_ms: 0, end_ms: 3000 },
      { sentence_id: "sent-0002", start_ms: 3000, end_ms: 6000 },
    ],
    checks: {
      missing_sentence_ids: [],
      zero_duration_sentence_ids: ["sent-0002"],
      abnormal_duration_sentence_ids: [],
    },
    ...overrides,
  }
}

export function makeStructureReport(
  overrides: Partial<StructureReportPayload> = {},
): StructureReportPayload {
  return {
    article_id: "art-0001",
    revision: 2,
    warnings: [],
    structure_tree: [],
    processing_counts: {
      translated_sentences: 12,
      translated_tables: 1,
      skipped_code_blocks: 2,
      narrated_sentences: 12,
    },
    ...overrides,
  }
}
