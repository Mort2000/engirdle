import 'package:flutter/material.dart';

import '../features/attribution/presentation/attribution_page.dart';
import '../features/connection/presentation/connection_offline_page.dart';
import '../features/connection/presentation/service_setup_page.dart';
import '../features/dictionary/presentation/dictionary_resources_page.dart';
import '../features/library/presentation/bookshelf_page.dart';
import '../features/preferences/presentation/playback_settings_page.dart';
import '../features/preferences/presentation/typography_settings_page.dart';
import '../features/reader/presentation/reader_page.dart';
import '../features/source_ingestion/presentation/paste_source_page.dart';
import '../features/translation/presentation/llm_settings_page.dart';
import '../features/translation/presentation/translation_task_page.dart';
import '../features/vocabulary/presentation/vocab_book_page.dart';
import '../features/vocabulary/presentation/vocab_detail_page.dart';

/// Named routes. Download/import is pushed as a MaterialPageRoute with its
/// typed catalog-package argument directly from the bookshelf.
class AppRoutes {
  AppRoutes._();

  static const bookshelf = '/';
  static const serviceSetup = '/service-setup';
  static const connectionOffline = '/connection-offline';
  static const reader = '/reader';
  static const vocabulary = '/vocabulary';
  static const vocabularyDetail = '/vocabulary/detail';
  static const typography = '/typography';
  static const playbackSettings = '/playback-settings';
  static const attribution = '/attribution';
  static const dictionaryResources = '/dictionary-resources';
  static const pasteSource = '/paste-source';
  static const translationSettings = '/translation-settings';
  static const translationTask = '/translation-task';

  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case bookshelf:
        return _page(const BookshelfPage(), settings);
      case serviceSetup:
        return _page(const ServiceSetupPage(), settings);
      case connectionOffline:
        return _page(const ConnectionOfflinePage(), settings);
      case reader:
        return _page(
          ReaderPage(articleId: settings.arguments! as String),
          settings,
        );
      case vocabulary:
        return _page(const VocabBookPage(), settings);
      case vocabularyDetail:
        return _page(
          VocabDetailPage(vocabularyId: settings.arguments! as String),
          settings,
        );
      case typography:
        return _page(const TypographySettingsPage(), settings);
      case playbackSettings:
        return _page(const PlaybackSettingsPage(), settings);
      case attribution:
        return _page(
          AttributionPage(articleId: settings.arguments! as String),
          settings,
        );
      case dictionaryResources:
        return _page(const DictionaryResourcesPage(), settings);
      case pasteSource:
        return _page(const PasteSourcePage(), settings);
      case translationSettings:
        return _page(const LlmSettingsPage(), settings);
      case translationTask:
        return _page(
          TranslationTaskPage(jobId: settings.arguments! as String),
          settings,
        );
      default:
        return _page(const BookshelfPage(), settings);
    }
  }

  static MaterialPageRoute<dynamic> _page(
    Widget child,
    RouteSettings settings,
  ) => MaterialPageRoute(builder: (_) => child, settings: settings);
}
