from __future__ import annotations

from pathlib import Path

from engirdle_pc.modules.content.domain.plan import NarrationUnit
from engirdle_pc.modules.speech.application.ports import (
    SPEECH_BATCHING,
    SentenceSpeech,
    SpeechAdapter,
    SpeechRequest,
    SpeechStore,
    VoiceProfileRef,
)


class InvalidSpeechResult(ValueError):
    """A speech adapter changed the sentence identity or returned unusable PCM."""


class SpeechService:
    def __init__(self, adapter: SpeechAdapter, store: SpeechStore) -> None:
        self._adapter = adapter
        self._store = store

    @property
    def batch_size(self) -> int:
        return self._adapter.batch_size

    @property
    def batching(self) -> str:
        return SPEECH_BATCHING

    def narration_batches(
        self, units: tuple[NarrationUnit, ...]
    ) -> tuple[tuple[NarrationUnit, ...], ...]:
        ordered = sorted(units, key=lambda unit: (len(unit.text), unit.order))
        return tuple(
            tuple(ordered[index:index + self.batch_size])
            for index in range(0, len(ordered), self.batch_size)
        )

    @property
    def name(self) -> str:
        return self._adapter.name

    @property
    def custom_voice_model(self) -> str:
        return self._adapter.custom_voice_model

    @property
    def base_model(self) -> str:
        return self._adapter.base_model

    @property
    def generation_config_id(self) -> str:
        return self._adapter.generation_config_id

    @property
    def voice_profile(self) -> VoiceProfileRef:
        return self._adapter.voice_profile

    def verify_setup(self) -> None:
        self._adapter.verify_setup()

    def synthesize_narration(
        self, job_id: str, unit: NarrationUnit, target_dir: Path
    ) -> SentenceSpeech:
        """Compatibility entry for a single narratable sentence."""
        return self.synthesize_narration_batch(job_id, (unit,), target_dir)[0]

    def synthesize_narration_batch(
        self, job_id: str, units: tuple[NarrationUnit, ...], target_dir: Path
    ) -> tuple[SentenceSpeech, ...]:
        """Only narration units enter TTS; validate the whole batch before saving."""
        if not units:
            return ()
        if len(units) > self.batch_size:
            raise InvalidSpeechResult("narration batch exceeds configured batch size")
        expected = tuple(unit.sentence_id for unit in units)
        if len(set(expected)) != len(expected):
            raise InvalidSpeechResult("narration batch contains duplicate sentence IDs")
        results = self._adapter.synthesize_batch(
            tuple(SpeechRequest(unit.sentence_id, unit.text) for unit in units), target_dir
        )
        if tuple(speech.sentence_id for speech in results) != expected:
            raise InvalidSpeechResult("speech adapter changed the batch sentence IDs or order")
        for speech in results:
            if (
                speech.sample_rate_hz != 24_000
                or speech.sample_count <= 0
                or not speech.pcm_path.is_file()
                or speech.pcm_path.stat().st_size != speech.sample_count * 2
            ):
                raise InvalidSpeechResult("speech adapter returned unusable PCM")
        for speech in results:
            self._store.save(job_id, speech, self.name)
        return results

    def reusable_for_job(self, job_id: str) -> tuple[SentenceSpeech, ...]:
        return self._store.list_reusable_for_job(job_id, self.name)
