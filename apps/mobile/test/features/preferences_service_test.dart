import 'package:engirdle_mobile/features/preferences/application/preferences_service.dart';
import 'package:engirdle_mobile/features/preferences/domain/playback_preferences.dart';
import 'package:engirdle_mobile/features/preferences/infrastructure/preferences_dao.dart';
import 'package:engirdle_mobile/platform/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('background music interruption is enabled by default', () {
    final database = AppDatabase.inMemory();
    addTearDown(database.close);

    final service = PreferencesService(dao: PreferencesDao(database.db));

    expect(service.playbackNotifier.value.interruptBackgroundAudio, isTrue);
  });

  test(
    'background music interruption preference survives service recreation',
    () {
      final database = AppDatabase.inMemory();
      addTearDown(database.close);
      final dao = PreferencesDao(database.db);
      final service = PreferencesService(dao: dao);

      service.updatePlayback(
        const PlaybackPreferences(interruptBackgroundAudio: false),
      );
      final restored = PreferencesService(dao: dao);

      expect(restored.playbackNotifier.value.interruptBackgroundAudio, isFalse);
    },
  );
}
