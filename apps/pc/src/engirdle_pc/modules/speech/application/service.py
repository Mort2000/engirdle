from __future__ import annotations

from pathlib import Path

from engirdle_pc.modules.content.domain.plan import NarrationUnit
from engirdle_pc.modules.speech.application.ports import (
    SentenceSpeech,
    SpeechAdapter,
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
        """Synthesize PCM for one narration unit (design §8.6).

        The ONLY speech entry the production worker may call: tables, code and
        dividers have no NarrationUnit, so no calling path can send them here.
        """
        speech = self._adapter.synthesize(unit.sentence_id, unit.text, target_dir)
        if speech.sentence_id != unit.sentence_id:
            raise InvalidSpeechResult("speech adapter changed the sentence ID")
        self._store.save(job_id, speech, self.name)
        return speech

    def reusable_for_job(self, job_id: str) -> tuple[SentenceSpeech, ...]:
        return self._store.list_reusable_for_job(job_id, self.name)
