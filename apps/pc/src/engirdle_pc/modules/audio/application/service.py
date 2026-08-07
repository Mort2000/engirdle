from __future__ import annotations

from pathlib import Path

from engirdle_pc.modules.audio.application.models import (
    AudioOutput,
    AudioReview,
    AudioReviewChecks,
)
from engirdle_pc.modules.audio.application.ports import AudioRenderer, AudioStore
from engirdle_pc.modules.content.public import ArticleRevision
from engirdle_pc.modules.speech.public import SentenceSpeech


class AudioService:
    def __init__(self, repository: AudioStore, renderer: AudioRenderer) -> None:
        self._repository = repository
        self._renderer = renderer

    def build(
        self,
        job_id: str,
        revision: ArticleRevision,
        speech_items: tuple[SentenceSpeech, ...],
        target_dir: Path,
    ) -> AudioOutput:
        output = self._renderer.render(revision, speech_items, target_dir)
        self._repository.save(job_id, output)
        return output

    def get(self, job_id: str) -> AudioOutput:
        return self._repository.get(job_id)

    def review(
        self, job_id: str, expected_sentence_ids: tuple[str, ...]
    ) -> AudioReview:
        output = self.get(job_id)
        timing_by_id = {timing.sentence_id: timing for timing in output.timings}
        missing = tuple(
            sentence_id
            for sentence_id in expected_sentence_ids
            if sentence_id not in timing_by_id
        )
        zero_duration = tuple(
            timing.sentence_id
            for timing in output.timings
            if timing.end_ms <= timing.start_ms
        )
        abnormal_duration = tuple(
            timing.sentence_id
            for timing in output.timings
            if timing.end_ms > timing.start_ms
            and (
                timing.end_ms - timing.start_ms < 200
                or timing.end_ms - timing.start_ms > 60_000
            )
        )
        return AudioReview(
            output=output,
            checks=AudioReviewChecks(
                missing_sentence_ids=missing,
                zero_duration_sentence_ids=zero_duration,
                abnormal_duration_sentence_ids=abnormal_duration,
            ),
        )
