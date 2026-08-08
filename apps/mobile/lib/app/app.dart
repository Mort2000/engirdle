import 'package:flutter/material.dart';

import '../features/playback/domain/playback_models.dart';
import '../features/playback/presentation/playback_bar.dart';
import '../features/preferences/domain/reading_preferences.dart';
import 'dependencies.dart';
import 'router.dart';
import 'scope.dart';
import 'theme.dart';

/// Root widget: palette + theme rebuild on preference changes; everything
/// below stays offline by default.
class EngirdleApp extends StatelessWidget {
  const EngirdleApp({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      dependencies: dependencies,
      child: ValueListenableBuilder<ReadingPreferences>(
        valueListenable: dependencies.preferences.notifier,
        builder: (context, prefs, _) {
          final palette = AppPalette.of(prefs.themePreset);
          return PaletteScope(
            palette: palette,
            child: MaterialApp(
              title: 'Engirdle',
              debugShowCheckedModeBanner: false,
              theme: buildTheme(palette),
              onGenerateRoute: AppRoutes.onGenerateRoute,
              initialRoute: AppRoutes.bookshelf,
              // A global mini playback bar above every route (design §8): with
              // background playback, the session outlives the reader, so the
              // user must be able to pause/stop without re-entering it.
              builder: (context, child) =>
                  _GlobalPlaybackHost(dependencies: dependencies, child: child!),
            ),
          );
        },
      ),
    );
  }
}

/// Hosts the current route and, below it, the global playback bar — but only
/// while a session is active. Using a Column (not a Stack overlay) means the
/// bar pushes the route up instead of covering its bottom content.
class _GlobalPlaybackHost extends StatelessWidget {
  const _GlobalPlaybackHost({required this.dependencies, required this.child});

  final AppDependencies dependencies;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlaybackSnapshot>(
      valueListenable: dependencies.playback.state,
      builder: (context, snapshot, _) {
        final bar = snapshot.isActive
            ? PlaybackBar(controller: dependencies.playback)
            : const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(child: child),
            bar,
          ],
        );
      },
    );
  }
}
