import 'package:engirdle_native/engirdle_native.dart' as native;

/// Best-effort POST_NOTIFICATIONS request before the first background
/// translation (design §9.3). Called from the queue flow on Android 13+;
/// denial only hides the progress notification — the work itself runs
/// either way, and the app never claims otherwise. Never throws: when the
/// platform service is unavailable (tests, in-process execution) this is a
/// silent no-op.
class TranslationNotificationPrompt {
  const TranslationNotificationPrompt();

  Future<void> requestIfNeeded() async {
    try {
      final enabled =
          await native.EngirdleTranslationNotifications.areEnabled();
      if (!enabled) {
        await native.EngirdleTranslationNotifications.requestPermission();
      }
    } catch (_) {
      // Platform channel unavailable — background notifications are off.
    }
  }
}
