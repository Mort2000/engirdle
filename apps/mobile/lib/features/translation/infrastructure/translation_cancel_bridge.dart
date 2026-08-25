import 'package:flutter/services.dart';

/// Forwards notification cancel actions into the translation module
/// (design §12.4). The notification's cancel action launches MainActivity
/// with a cancel intent; the activity buffers the job id across the cold
/// start (before Dart is up) and pushes it live while the engine is warm.
/// This bridge pulls once at startup and subscribes to pushes — both
/// deliver the job id to the same module.cancel path as the on-screen
/// buttons.
class TranslationCancelBridge {
  TranslationCancelBridge({required this.onCancel});

  final void Function(String jobId) onCancel;

  static const MethodChannel _channel = MethodChannel('com.engirdle.mobile/app');

  void install() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'translationCancelRequested') {
        final jobId = call.arguments as String?;
        if (jobId != null && jobId.isNotEmpty) onCancel(jobId);
      }
      return null;
    });
    _channel
        .invokeMethod<String>('takePendingTranslationCancel')
        .then((jobId) {
          if (jobId != null && jobId.isNotEmpty) onCancel(jobId);
        })
        .catchError((Object _) {});
  }
}
