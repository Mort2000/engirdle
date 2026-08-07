from __future__ import annotations

from dataclasses import dataclass

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.modules.audio.infrastructure.ffmpeg_encoder import FfmpegAudioEncoder
from engirdle_pc.modules.audio.infrastructure.local_renderer import LocalAudioRenderer
from engirdle_pc.modules.audio.infrastructure.sqlite_repository import AudioRepository
from engirdle_pc.modules.audio.public import AudioService
from engirdle_pc.modules.content.application.service import ContentService
from engirdle_pc.modules.content.infrastructure.source_store import FileSourceSnapshotStore
from engirdle_pc.modules.content.infrastructure.sqlite_repository import ContentRepository
from engirdle_pc.modules.packaging.infrastructure.sqlite_repository import ArtifactRepository
from engirdle_pc.modules.packaging.infrastructure.validator import ReadpackValidator
from engirdle_pc.modules.packaging.infrastructure.zip_writer import ZipPackageWriter
from engirdle_pc.modules.packaging.public import PackagingService
from engirdle_pc.modules.production.infrastructure.sqlite_repository import JobRepository
from engirdle_pc.modules.production.public import ProductionService, ProductionWorker
from engirdle_pc.modules.publishing.infrastructure.file_store import (
    LocalPublicationFileStore,
)
from engirdle_pc.modules.publishing.infrastructure.process_controller import (
    PublisherProcessController,
    PublisherProcessLauncher,
)
from engirdle_pc.modules.publishing.infrastructure.query_service import PublisherQueries
from engirdle_pc.modules.publishing.infrastructure.sqlite_repository import (
    PublishingRepository,
)
from engirdle_pc.modules.publishing.infrastructure.validator import CatalogValidator
from engirdle_pc.modules.publishing.public import (
    CatalogValidation,
    LocalLibraryService,
    PublisherControl,
    PublishingService,
    ReleaseService,
)
from engirdle_pc.modules.speech.infrastructure.sqlite_repository import SpeechRepository
from engirdle_pc.modules.speech.infrastructure.stub_adapter import StubSpeechAdapter
from engirdle_pc.modules.speech.public import (
    SpeechAdapter,
    SpeechService,
)
from engirdle_pc.modules.translation.infrastructure.sqlite_repository import (
    TranslationRepository,
)
from engirdle_pc.modules.translation.infrastructure.stub_adapter import (
    StubTranslationAdapter,
)
from engirdle_pc.modules.translation.public import (
    TranslationAdapter,
    TranslationService,
)
from engirdle_pc.shared.infrastructure.database.connection import Database
from engirdle_pc.shared.infrastructure.runtime import (
    SystemClock,
    UuidIdentifierGenerator,
)
from engirdle_pc.shared.infrastructure.workspace import Workspace


@dataclass(frozen=True)
class Container:
    settings: Settings
    content: ContentService
    production: ProductionService
    translations: TranslationService
    audio: AudioService
    worker: ProductionWorker
    release: ReleaseService
    publishing: PublishingService
    publisher_queries: PublisherQueries
    publisher_process: PublisherControl
    local_library: LocalLibraryService

    @classmethod
    def build(
        cls,
        settings: Settings,
        *,
        translation_adapter: TranslationAdapter | None = None,
        speech_adapter: SpeechAdapter | None = None,
        catalog_validator: CatalogValidation | None = None,
        publisher_process_launcher: PublisherProcessLauncher | None = None,
    ) -> Container:
        workspace = Workspace(settings.workspace)
        workspace.initialize()
        database = Database(settings.database_path)
        database.initialize()
        clock = SystemClock()
        identifiers = UuidIdentifierGenerator()

        content_repository = ContentRepository(database)
        content = ContentService(
            content_repository,
            FileSourceSnapshotStore(workspace),
            clock,
            identifiers,
        )
        jobs = JobRepository(database, clock, identifiers)
        translation_repository = TranslationRepository(database)
        speech_repository = SpeechRepository(database)
        audio_repository = AudioRepository(database)
        artifacts = ArtifactRepository(database)
        publishing_repository = PublishingRepository(database)

        translator = translation_adapter or StubTranslationAdapter(identifiers)
        synthesizer = speech_adapter or StubSpeechAdapter()
        translations = TranslationService(translator, translation_repository)
        speech = SpeechService(synthesizer, speech_repository)
        encoder = FfmpegAudioEncoder(settings.ffmpeg_path)
        audio = AudioService(
            audio_repository,
            LocalAudioRenderer(
                encoder,
                settings.sentence_pause_ms,
                settings.block_pause_ms,
            ),
        )
        production = ProductionService(jobs, translations, speech)
        worker = ProductionWorker(
            jobs,
            content,
            translations,
            speech,
            audio,
            workspace,
        )
        validator = ReadpackValidator(settings.contracts_dir)
        packaging = PackagingService(
            artifacts,
            content,
            translations,
            audio,
            ZipPackageWriter(workspace, validator),
            clock,
            identifiers,
        )
        catalog_validation = catalog_validator or CatalogValidator(
            settings.contracts_dir
        )
        publication_files = LocalPublicationFileStore(
            workspace, catalog_validation, identifiers
        )
        publishing = PublishingService(
            publishing_repository,
            publication_files,
            content,
            production,
            packaging,
            clock,
        )
        release = ReleaseService(production, packaging, publishing)
        publisher_queries = PublisherQueries(workspace)
        publisher_process = PublisherProcessController(
            settings.workspace,
            settings.publisher_host,
            settings.publisher_port,
            clock,
            identifiers,
            publisher_process_launcher,
        )
        local_library = LocalLibraryService(
            publishing,
            packaging,
            production,
            content,
            publication_files,
        )
        return cls(
            settings=settings,
            content=content,
            production=production,
            translations=translations,
            audio=audio,
            worker=worker,
            release=release,
            publishing=publishing,
            publisher_queries=publisher_queries,
            publisher_process=publisher_process,
            local_library=local_library,
        )
