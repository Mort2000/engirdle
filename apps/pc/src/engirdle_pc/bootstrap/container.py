from __future__ import annotations

from dataclasses import dataclass

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.modules.audio.infrastructure.ffmpeg_encoder import FfmpegAudioEncoder
from engirdle_pc.modules.audio.infrastructure.local_renderer import LocalAudioRenderer
from engirdle_pc.modules.audio.infrastructure.sqlalchemy_repository import (
    SqlAlchemyAudioRepository,
)
from engirdle_pc.modules.audio.public import AudioService
from engirdle_pc.modules.content.application.service import ContentService
from engirdle_pc.modules.content.infrastructure.source_store import FileSourceSnapshotStore
from engirdle_pc.modules.content.infrastructure.sqlalchemy_repository import (
    SqlAlchemyContentRepository,
)
from engirdle_pc.modules.packaging.infrastructure.sqlalchemy_repository import (
    SqlAlchemyArtifactRepository,
)
from engirdle_pc.modules.packaging.infrastructure.validator import ReadpackValidator
from engirdle_pc.modules.packaging.infrastructure.zip_writer import ZipPackageWriter
from engirdle_pc.modules.packaging.public import PackagingService
from engirdle_pc.modules.production.infrastructure.sqlalchemy_repository import (
    SqlAlchemyJobRepository,
)
from engirdle_pc.modules.production.public import ProductionService, ProductionWorker
from engirdle_pc.modules.publishing.infrastructure.file_store import (
    LocalPublicationFileStore,
)
from engirdle_pc.modules.publishing.infrastructure.process_controller import (
    PublisherProcessController,
    PublisherProcessLauncher,
)
from engirdle_pc.modules.publishing.infrastructure.query_service import PublisherQueries
from engirdle_pc.modules.publishing.infrastructure.sqlalchemy_repository import (
    SqlAlchemyPublishingRepository,
)
from engirdle_pc.modules.publishing.infrastructure.validator import CatalogValidator
from engirdle_pc.modules.publishing.public import (
    CatalogValidation,
    LocalLibraryService,
    PublisherControl,
    PublishingService,
    ReleaseService,
)
from engirdle_pc.modules.speech.infrastructure.qwen3_adapter import (
    build_qwen3_speech_adapter,
)
from engirdle_pc.modules.speech.infrastructure.qwen3_backend import LocalQwen3Backend
from engirdle_pc.modules.speech.infrastructure.qwen3_custom_voice import (
    Qwen3AnchorEngine,
)
from engirdle_pc.modules.speech.infrastructure.sqlalchemy_repository import (
    SqlAlchemySpeechRepository,
    SqlAlchemyVoiceProfileRepository,
)
from engirdle_pc.modules.speech.public import (
    AnchorEngine,
    SpeechAdapter,
    SpeechService,
    VoiceProfileService,
)
from engirdle_pc.modules.translation.infrastructure.deepseek_adapter import (
    build_deepseek_adapter,
)
from engirdle_pc.modules.translation.infrastructure.sqlalchemy_repository import (
    SqlAlchemyTranslationRepository,
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
    speech: SpeechService
    voices: VoiceProfileService
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
        deepseek_api_key: str | None = None,
        speech_adapter: SpeechAdapter | None = None,
        anchor_engine: AnchorEngine | None = None,
        catalog_validator: CatalogValidation | None = None,
        publisher_process_launcher: PublisherProcessLauncher | None = None,
    ) -> Container:
        workspace = Workspace(settings.workspace)
        workspace.initialize()
        database = Database(settings.database_path)
        database.initialize()
        clock = SystemClock()
        identifiers = UuidIdentifierGenerator()

        content_repository = SqlAlchemyContentRepository(database)
        content = ContentService(
            content_repository,
            FileSourceSnapshotStore(workspace),
            clock,
            identifiers,
        )
        jobs = SqlAlchemyJobRepository(database, clock, identifiers)
        translation_repository = SqlAlchemyTranslationRepository(database)
        speech_repository = SqlAlchemySpeechRepository(database)
        voice_profiles = SqlAlchemyVoiceProfileRepository(database)
        audio_repository = SqlAlchemyAudioRepository(database)
        artifacts = SqlAlchemyArtifactRepository(database)
        publishing_repository = SqlAlchemyPublishingRepository(database)

        translator = translation_adapter or build_deepseek_adapter(
            settings, deepseek_api_key, identifiers
        )
        # One shared backend instance enforces design §4.5.1 (CustomVoice and
        # Base are never resident together) across both speech paths in this
        # process; constructing it is cheap — model loading stays lazy.
        speech_backend = LocalQwen3Backend(
            custom_voice_dir=settings.custom_voice_model_dir,
            base_dir=settings.base_model_dir,
            device=settings.speech_device,
            dtype=settings.speech_dtype,
            attn_implementation=settings.speech_attn_implementation,
        )
        synthesizer = speech_adapter or build_qwen3_speech_adapter(
            settings, voice_profiles, backend=speech_backend
        )
        translations = TranslationService(translator, translation_repository)
        speech = SpeechService(synthesizer, speech_repository)
        engine = anchor_engine or Qwen3AnchorEngine(
            speech_backend,
            custom_voice_dir=settings.custom_voice_model_dir,
            max_new_tokens=settings.speech_max_new_tokens,
        )
        voices = VoiceProfileService(
            engine, voice_profiles, workspace.voices_dir, clock, identifiers
        )
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
            speech=speech,
            voices=voices,
            audio=audio,
            worker=worker,
            release=release,
            publishing=publishing,
            publisher_queries=publisher_queries,
            publisher_process=publisher_process,
            local_library=local_library,
        )
