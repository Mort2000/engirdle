import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'app/dependencies.dart';
import 'features/playback/application/audio_focus_port.dart';
import 'features/playback/infrastructure/audio_session_adapter.dart';
import 'platform/filesystem/app_directories.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final supportDir = await getApplicationSupportDirectory();
  // Configure the speech/audiobook audio session before building the graph so
  // the playback focus adapter observes interruptions/route changes from the
  // start (design §7.1). A failure here must not block app startup: playback
  // still works without focus events (just_audio activates the session itself).
  AudioFocusPort focusPort;
  try {
    focusPort = await AudioSessionAdapter.init();
  } catch (_) {
    focusPort = _NullFocusPort();
  }
  final dependencies = await AppDependencies.build(
    directories: AppDirectories(supportDir),
    focusPort: focusPort,
  );
  // Startup recovery: interrupted imports are completed or rolled back
  // before any UI interaction (design §8.2).
  await dependencies.recoverImports();
  runApp(EngirdleApp(dependencies: dependencies));
}

/// No-op focus port used only when the platform audio session cannot be
/// configured at startup. It never emits, so the coordinator simply never
/// reacts to interruptions — playback still works via just_audio.
class _NullFocusPort implements AudioFocusPort {
  @override
  Stream<AudioFocusEvent> get events => const Stream<AudioFocusEvent>.empty();
}
