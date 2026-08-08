import 'package:flutter/widgets.dart';

import 'dependencies.dart';

/// Exposes the composition root to the widget tree.
class AppScope extends InheritedWidget {
  const AppScope({required this.dependencies, required super.child, super.key});

  final AppDependencies dependencies;

  static AppDependencies of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.dependencies;

  @override
  bool updateShouldNotify(AppScope oldWidget) => false;
}
