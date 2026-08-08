import 'package:flutter/foundation.dart';

import '../domain/reading_preferences.dart';
import '../infrastructure/preferences_dao.dart';

/// Loads, exposes and persists global reading preferences (MOB-READ-004).
/// Widgets subscribe to [notifier]; changes apply immediately and survive
/// restarts.
class PreferencesService {
  PreferencesService({required PreferencesDao dao}) : _dao = dao {
    _load();
  }

  final PreferencesDao _dao;

  final ValueNotifier<ReadingPreferences> notifier =
      ValueNotifier(const ReadingPreferences());

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
          parse('font_family', ReaderFontFamily.values) ?? ReaderFontFamily.serif,
      fontSize: parse('font_size', ReaderFontSize.values) ??
          ReaderFontSize.standard,
      lineHeight: parse('line_height', ReaderLineHeight.values) ??
          ReaderLineHeight.comfortable,
      margin: parse('margin', ReaderMargin.values) ?? ReaderMargin.standard,
      themePreset: parse('theme_preset', ReaderThemePreset.values) ??
          ReaderThemePreset.paper,
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
}
