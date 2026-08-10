import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'app/dependencies.dart';
import 'features/playback/application/audio_focus_port.dart';
import 'features/playback/infrastructure/audio_session_adapter.dart';
import 'features/playback/infrastructure/audio_service_handler_adapter.dart';
import 'platform/filesystem/app_directories.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final supportDir = await getApplicationSupportDirectory();
  // Configure the speech/audiobook audio session before building the graph so
  // the playback focus adapter observes interruptions/route changes from the
  // start (design §7.1). A failure here must not block app startup: playback
  // still works without focus events; focus acquisition is best-effort.
  AudioFocusPort focusPort;
  try {
    focusPort = await AudioSessionAdapter.init();
  } catch (_) {
    focusPort = const NullAudioFocusPort();
  }
  final dependencies = await AppDependencies.build(
    directories: AppDirectories(supportDir),
    focusPort: focusPort,
  );
  // Register the foreground media Service / MediaSession and bind it to the
  // coordinator (design §7.1, step 4). Best-effort: a failure must not block
  // the app — playback still works without the system media service.
  try {
    final handler = await AudioService.init<EngirdleAudioHandler>(
      builder: () => EngirdleAudioHandler(dependencies.playback),
      config: _audioServiceConfig,
    );
    handler.bind();
  } catch (_) {
    // System media controls unavailable; local playback is unaffected.
  }
  // Step 5: recover interrupted imports, then start the UI.
  await dependencies.recoverImports();
  runApp(EngirdleApp(dependencies: dependencies));
}

const _audioServiceConfig = AudioServiceConfig(
  androidNotificationChannelId: 'com.engirdle.mobile.playback',
  androidNotificationChannelName: '朗读播放',
  androidNotificationClickStartsActivity: true,
  androidStopForegroundOnPause: true,
  fastForwardInterval: Duration(seconds: 10),
  rewindInterval: Duration(seconds: 10),
);
