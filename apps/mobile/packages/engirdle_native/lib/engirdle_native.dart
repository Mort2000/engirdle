/// Dart face of the native services plugin. As a registered plugin it is
/// attached to every Flutter engine — including the headless engine
/// WorkManager spawns for the translation worker (design §9.2) — unlike
/// channels registered in MainActivity, which exist only on the UI engine.
library;

import 'package:flutter/services.dart';

/// Keystore-backed secret store (design §10.1). Secrets never enter the
/// database, WorkManager input data, logs or backups.
class EngirdleSecrets {
  const EngirdleSecrets._();

  static const MethodChannel _channel = MethodChannel('engirdle.native/secrets');

  static Future<String?> read(String alias) =>
      _channel.invokeMethod<String>('read', {'alias': alias});

  static Future<void> write(String alias, String secret) =>
      _channel.invokeMethod<void>('write', {'alias': alias, 'secret': secret});

  static Future<void> delete(String alias) =>
      _channel.invokeMethod<void>('delete', {'alias': alias});
}

/// Translation progress / waiting / result notifications (§9.2/§12.4).
class EngirdleTranslationNotifications {
  const EngirdleTranslationNotifications._();

  static const MethodChannel _channel = MethodChannel(
    'engirdle.native/translation_notifications',
  );

  static Future<void> progress({
    required String jobId,
    required String title,
    required int done,
    required int total,
  }) => _channel.invokeMethod<void>('progress', {
    'jobId': jobId,
    'title': title,
    'done': done,
    'total': total,
  });

  static Future<void> waiting({required String jobId, required String title}) =>
      _channel.invokeMethod<void>('waiting', {'jobId': jobId, 'title': title});

  static Future<void> finished({
    required String jobId,
    required String title,
    required bool succeeded,
  }) => _channel.invokeMethod<void>('finished', {
    'jobId': jobId,
    'title': title,
    'succeeded': succeeded,
  });

  /// Clears the job's waiting/summary notifications (cancel/pause, §12.4).
  static Future<void> dismiss({required String jobId}) =>
      _channel.invokeMethod<void>('dismiss', {'jobId': jobId});

  static Future<bool> areEnabled() async =>
      await _channel.invokeMethod<bool>('areEnabled') ?? false;

  /// Fire-and-forget POST_NOTIFICATIONS request (Android 13+). Returns the
  /// CURRENT grant state, not the eventual one — the system dialog resolves
  /// asynchronously; callers that care re-query [areEnabled]. Denial hides
  /// notifications but never blocks the work (§9.3).
  static Future<bool> requestPermission() async =>
      await _channel.invokeMethod<bool>('requestPermission') ?? false;
}
