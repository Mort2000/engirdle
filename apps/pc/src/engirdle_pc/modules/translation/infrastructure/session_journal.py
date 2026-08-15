"""Durable per-checkpoint journal for DeepSeek translation sessions.

The DeepSeek API has no server-side session state, so the logical session
(message history) is reconstructed on every call. This journal durably records
the accepted unit replies for a 'checkpoint_id' so the session can be rebuilt
even across process restarts (lease recovery).

The code-free context and each unit's request are rebuilt deterministically
from the immutable ArticleRevision + ProcessingPlan (and the deterministic
protected-token map), so the journal only persists the accepted reply content
keyed by 'unit_id'. Code bodies are never journaled because they are never
part of a request or reply.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

from engirdle_pc.modules.translation.infrastructure.deepseek_errors import (
    TranslationProtocolError,
)


@dataclass
class TranslationSessionJournal:
    checkpoint_id: str
    source_sha256: str
    prompt_version: str
    accepted: dict[str, str] = field(default_factory=dict)
    _path: Path | None = None

    @classmethod
    def create(
        cls,
        *,
        directory: Path,
        checkpoint_id: str,
        source_sha256: str,
        prompt_version: str,
    ) -> TranslationSessionJournal:
        journal = cls(
            checkpoint_id=checkpoint_id,
            source_sha256=source_sha256,
            prompt_version=prompt_version,
            _path=_journal_path(directory, checkpoint_id),
        )
        journal._save()
        return journal

    @classmethod
    def load(cls, directory: Path, checkpoint_id: str) -> TranslationSessionJournal | None:
        path = _journal_path(directory, checkpoint_id)
        if not path.exists():
            return None
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            return cls(
                checkpoint_id=payload["checkpoint_id"],
                source_sha256=payload["source_sha256"],
                prompt_version=payload["prompt_version"],
                accepted={
                    str(unit_id): str(reply)
                    for unit_id, reply in payload.get("accepted_units", {}).items()
                },
                _path=path,
            )
        except (json.JSONDecodeError, KeyError, TypeError) as error:
            # A corrupt/partial journal (disk error, interrupted write, schema
            # drift) must surface as a typed translation error, not an opaque
            # JSONDecodeError that escapes the worker's TranslationError handling.
            raise TranslationProtocolError(
                f"translation session journal for checkpoint {checkpoint_id} is corrupt"
            ) from error

    def accept_unit(self, unit_id: str, reply: str) -> None:
        # Overwrite on retry of the same unit; order is irrelevant to rebuild.
        self.accepted[unit_id] = reply
        self._save()

    def _save(self) -> None:
        assert self._path is not None
        self._path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "checkpoint_id": self.checkpoint_id,
            "source_sha256": self.source_sha256,
            "prompt_version": self.prompt_version,
            "accepted_units": self.accepted,
        }
        tmp = self._path.with_suffix(self._path.suffix + ".tmp")
        tmp.write_text(
            json.dumps(payload, ensure_ascii=False, sort_keys=True),
            encoding="utf-8",
        )
        os.replace(tmp, self._path)


def _journal_path(directory: Path, checkpoint_id: str) -> Path:
    # checkpoint_id is a UUID minted by the adapter; sanitize defensively.
    safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in checkpoint_id)
    return directory / f"{safe}.json"
