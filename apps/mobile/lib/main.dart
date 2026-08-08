import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'app/dependencies.dart';
import 'platform/filesystem/app_directories.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final supportDir = await getApplicationSupportDirectory();
  final dependencies = await AppDependencies.build(
    directories: AppDirectories(supportDir),
  );
  // Startup recovery: interrupted imports are completed or rolled back
  // before any UI interaction (design §8.2).
  await dependencies.recoverImports();
  runApp(EngirdleApp(dependencies: dependencies));
}
