from __future__ import annotations

from dataclasses import dataclass

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.modules.audio.public import (
    AudioRepository,
    AudioService,
    FfmpegAudioEncoder,
)
from engirdle_pc.modules.content.application.service import ContentService
from engirdle_pc.modules.content.infrastructure.sqlite_repository import ContentRepository
from engirdle_pc.modules.packaging.public import (
    ArtifactRepository,
    PackagingService,
    ReadpackValidator,
)
from engirdle_pc.modules.production.public import (
    JobRepository,
    ProductionService,
    ProductionWorker,
)
from engirdle_pc.modules.publishing.public import (
    CatalogValidator,
    LocalLibraryService,
    PublisherQueries,
    PublishingRepository,
    PublishingService,
    ReleaseService,
)
from engirdle_pc.modules.speech.public import SpeechRepository, StubSpeechAdapter
from engirdle_pc.modules.translation.public import (
    StubTranslationAdapter,
    TranslationAdapter,
    TranslationRepository,
)
from engirdle_pc.shared.infrastructure.database.connection import Database
from engirdle_pc.shared.infrastructure.workspace import Workspace


@dataclass(frozen=True)
class Container:
    settings: Settings
    content: ContentService
    production: ProductionService
    jobs: JobRepository
    translations: TranslationRepository
    audio: AudioService
    worker: ProductionWorker
    release: ReleaseService
    publishing: PublishingService
    publisher_queries: PublisherQueries
    local_library: LocalLibraryService

    @classmethod
    def build(
        cls,
        settings: Settings,
        *,
        translation_adapter: TranslationAdapter | None = None,
    ) -> Container:
        workspace = Workspace(settings.workspace)
        workspace.initialize()
        database = Database(settings.database_path)
        database.initialize()

        content_repository = ContentRepository(database)
        content = ContentService(content_repository, workspace)
        jobs = JobRepository(database)
        translations = TranslationRepository(database)
        speech_repository = SpeechRepository(database)
        audio_repository = AudioRepository(database)
        artifacts = ArtifactRepository(database)
        publishing_repository = PublishingRepository(database)

        translator = translation_adapter or StubTranslationAdapter()
        speech_adapter = StubSpeechAdapter()
        encoder = FfmpegAudioEncoder(settings.ffmpeg_path)
        audio = AudioService(
            audio_repository,
            encoder,
            settings.sentence_pause_ms,
            settings.block_pause_ms,
        )
        production = ProductionService(jobs, translator, speech_adapter)
        worker = ProductionWorker(
            jobs,
            content,
            translator,
            translations,
            speech_adapter,
            speech_repository,
            audio,
            workspace,
        )
        validator = ReadpackValidator(settings.contracts_dir)
        packaging = PackagingService(
            artifacts, content, translations, audio, validator, workspace
        )
        publishing = PublishingService(
            publishing_repository,
            workspace,
            content,
            jobs,
            CatalogValidator(settings.contracts_dir),
        )
        release = ReleaseService(jobs, packaging, publishing)
        publisher_queries = PublisherQueries(publishing_repository, workspace)
        local_library = LocalLibraryService(
            publishing,
            artifacts,
            jobs,
            content,
            workspace,
        )
        return cls(
            settings=settings,
            content=content,
            production=production,
            jobs=jobs,
            translations=translations,
            audio=audio,
            worker=worker,
            release=release,
            publishing=publishing,
            publisher_queries=publisher_queries,
            local_library=local_library,
        )
