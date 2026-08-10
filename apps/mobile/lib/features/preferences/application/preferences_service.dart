import 'package:flutter/foundation.dart';

import '../../playback/application/playback_settings_port.dart';
import '../domain/playback_preferences.dart';
import '../domain/reading_preferences.dart';
import '../infrastructure/preferences_dao.dart';

/// Loads, exposes and persists global reading and playback preferences.
/// Widgets subscribe to the relevant notifier; changes apply immediately and
/// survive restarts.
class PreferencesService implements PlaybackSettingsPort {
  PreferencesService({required PreferencesDao dao}) : _dao = dao {
    _load();
  }

  final PreferencesDao _dao;

  final ValueNotifier<ReadingPreferences> notifier = ValueNotifier(
    const ReadingPreferences(),
  );

  final ValueNotifier<PlaybackPreferences> playbackNotifier = ValueNotifier(
    const PlaybackPreferences(),
  );

  @override
  bool get interruptBackgroundAudio =>
      playbackNotifier.value.interruptBackgroundAudio;

  void _load() {
    T? parse<T extends Enum>(String key, List<T> values) {
      final name = _dao.get(key);
      if (name == null) return null;
      for (final value in values) {
        if (value.name == name) return value;
      }
      return null;
    }

    notifier.value = ReadingPreferences(
      fontFamily:
          parse('font_family', ReaderFontFamily.values) ??
          ReaderFontFamily.serif,
      fontSize:
          parse('font_size', ReaderFontSize.values) ?? ReaderFontSize.standard,
      lineHeight:
          parse('line_height', ReaderLineHeight.values) ??
          ReaderLineHeight.comfortable,
      margin: parse('margin', ReaderMargin.values) ?? ReaderMargin.standard,
      themePreset:
          parse('theme_preset', ReaderThemePreset.values) ??
          ReaderThemePreset.paper,
    );
    playbackNotifier.value = PlaybackPreferences(
      interruptBackgroundAudio:
          _dao.get('interrupt_background_audio') != 'false',
    );
  }

  void update(ReadingPreferences preferences) {
    notifier.value = preferences;
    _dao.set('font_family', preferences.fontFamily.name);
    _dao.set('font_size', preferences.fontSize.name);
    _dao.set('line_height', preferences.lineHeight.name);
    _dao.set('margin', preferences.margin.name);
    _dao.set('theme_preset', preferences.themePreset.name);
  }

  void updatePlayback(PlaybackPreferences preferences) {
    playbackNotifier.value = preferences;
    _dao.set(
      'interrupt_background_audio',
      preferences.interruptBackgroundAudio.toString(),
    );
  }
}
