from __future__ import annotations

import wave
from array import array
from pathlib import Path

from engirdle_pc.modules.audio.application.errors import InvalidSentenceAudio
from engirdle_pc.modules.audio.application.models import AudioOutput
from engirdle_pc.modules.audio.application.ports import AudioEncoder
from engirdle_pc.modules.audio.domain.models import SentenceTiming
from engirdle_pc.modules.content.public import NarrationPlan, SentencePauseKind
from engirdle_pc.modules.speech.public import SentenceSpeech


class LocalAudioRenderer:
    def __init__(
        self,
        encoder: AudioEncoder,
        sentence_pause_ms: int,
        block_pause_ms: int,
    ) -> None:
        self._encoder = encoder
        self._sentence_pause_ms = sentence_pause_ms
        self._block_pause_ms = block_pause_ms

    def render(
        self,
        narration: NarrationPlan,
        speech_items: tuple[SentenceSpeech, ...],
        target_dir: Path,
    ) -> AudioOutput:
        speech_by_id = {item.sentence_id: item for item in speech_items}
        expected_ids = set(narration.sentence_ids)
        if set(speech_by_id) != expected_ids:
            raise InvalidSentenceAudio(
                "speech sentence IDs do not match the narration plan"
            )

        sample_rate = 24_000
        timeline = array("h")
        timings: list[SentenceTiming] = []
        units = narration.units
        for item_index, unit in enumerate(units):
            speech = speech_by_id[unit.sentence_id]
            if speech.sample_rate_hz != sample_rate or speech.sample_count <= 0:
                raise InvalidSentenceAudio(
                    f"invalid PCM metadata for {unit.sentence_id}"
                )
            content = speech.pcm_path.read_bytes()
            if len(content) != speech.sample_count * 2:
                raise InvalidSentenceAudio(
                    f"invalid PCM length for {unit.sentence_id}"
                )
            start_sample = len(timeline)
            sentence_samples = array("h")
            sentence_samples.frombytes(content)
            timeline.extend(sentence_samples)
            end_sample = len(timeline)
            timings.append(
                SentenceTiming(
                    sentence_id=unit.sentence_id,
                    start_sample=start_sample,
                    end_sample=end_sample,
                    start_ms=start_sample * 1000 // sample_rate,
                    end_ms=(end_sample * 1000 + sample_rate - 1) // sample_rate,
                )
            )
            if item_index < len(units) - 1:
                # A unit ending a text block applies the block pause even when
                # the next narratable sentence sits beyond a table or code block
                # (design §8.6: no extra silence for skipped content).
                pause_ms = (
                    self._block_pause_ms
                    if unit.pause_kind
                    in {SentencePauseKind.BLOCK_END, SentencePauseKind.ARTICLE_END}
                    else self._sentence_pause_ms
                )
                timeline.extend([0] * (sample_rate * pause_ms // 1000))

        _normalize_peak(timeline)
        target_dir.mkdir(parents=True, exist_ok=True)
        wav_path = target_dir / "article.wav"
        with wave.open(str(wav_path), "wb") as wav_file:
            wav_file.setnchannels(1)
            wav_file.setsampwidth(2)
            wav_file.setframerate(sample_rate)
            wav_file.writeframes(timeline.tobytes())
        output_path = target_dir / "article.m4a"
        self._encoder.encode_aac(wav_path, output_path)
        return AudioOutput(
            path=output_path,
            sample_rate_hz=sample_rate,
            channels=1,
            duration_ms=(len(timeline) * 1000 + sample_rate - 1) // sample_rate,
            encoder_version=self._encoder.version,
            timings=tuple(timings),
        )


def _normalize_peak(samples: array[int]) -> None:
    if not samples:
        raise InvalidSentenceAudio("article audio must not be empty")
    peak = max(abs(sample) for sample in samples)
    if peak == 0:
        raise InvalidSentenceAudio("article audio must not be silent")
    factor = 23_197 / peak
    for index, sample in enumerate(samples):
        samples[index] = max(-32_768, min(32_767, round(sample * factor)))
