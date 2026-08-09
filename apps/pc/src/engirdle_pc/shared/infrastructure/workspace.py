from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Workspace:
    root: Path

    def initialize(self) -> None:
        for path in (
            self.source_dir,
            self.working_dir,
            self.tts_cache_dir,
            self.voices_dir,
            self.artifacts_dir,
            self.public_packages_dir,
            self.public_dictionaries_dir,
        ):
            path.mkdir(parents=True, exist_ok=True)

    @property
    def source_dir(self) -> Path:
        return self.root / "source"

    @property
    def working_dir(self) -> Path:
        return self.root / "working"

    @property
    def tts_cache_dir(self) -> Path:
        return self.root / "cache" / "tts"

    @property
    def voices_dir(self) -> Path:
        return self.root / "voices"

    @property
    def artifacts_dir(self) -> Path:
        return self.root / "artifacts"

    @property
    def public_dir(self) -> Path:
        return self.root / "public"

    @property
    def public_packages_dir(self) -> Path:
        return self.public_dir / "packages"

    @property
    def public_dictionaries_dir(self) -> Path:
        return self.public_dir / "dictionaries"

    def source_revision_dir(self, article_id: str, revision: int) -> Path:
        return self.source_dir / article_id / str(revision)

    def job_dir(self, job_id: str) -> Path:
        return self.working_dir / job_id

    def artifact_dir(self, article_id: str, revision: int, artifact_revision: int) -> Path:
        return self.artifacts_dir / article_id / str(revision) / str(artifact_revision)
