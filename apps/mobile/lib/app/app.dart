import 'package:flutter/material.dart';

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
            ),
          );
        },
      ),
    );
  }
}
