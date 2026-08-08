import 'package:engirdle_mobile/app/app.dart';
import 'package:engirdle_mobile/app/dependencies.dart';
import 'package:engirdle_mobile/features/preferences/presentation/typography_settings_page.dart';
import 'package:engirdle_mobile/features/vocabulary/presentation/vocab_book_page.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_helpers.dart';

/// Widget smoke tests: the app shell, first-run routing and the main
/// secondary pages render against an in-memory dependency graph.
///
/// Dependencies are built in setUp: testWidgets bodies run under FakeAsync,
/// where real IO futures (temp dirs, sqlite) never advance.
void main() {
  late AppDependencies deps;

  setUp(() async {
    deps = await newTestDependencies();
  });

  testWidgets('first run opens the bookshelf then routes to service setup',
      (tester) async {
    await tester.pumpWidget(EngirdleApp(dependencies: deps));

    // The bookshelf (screen 03) is the home page before any routing happens.
    await tester.pump();
    expect(find.text('书架'), findsOneWidget);

    // Without a configured endpoint, first run pushes the setup flow (01).
    await tester.pumpAndSettle();
    expect(find.text('连接内容服务'), findsOneWidget);
    expect(find.text('欢迎使用 Engirdle'), findsOneWidget);
  });

  testWidgets('vocabulary book renders its empty state', (tester) async {
    await tester.pumpWidget(wrapTestWidget(deps, const VocabBookPage()));
    await tester.pumpAndSettle();
    expect(find.text('生词本'), findsOneWidget);
    expect(find.text('0 条 · 按保存时间排序'), findsOneWidget);
    expect(find.text('生词本还是空的'), findsOneWidget);
  });

  testWidgets('typography settings render the three presets', (tester) async {
    await tester
        .pumpWidget(wrapTestWidget(deps, const TypographySettingsPage()));
    await tester.pumpAndSettle();
    expect(find.text('排版与主题'), findsWidgets);
    expect(
        find.text('仅提供预设主题，不提供自定义取色器（MVP 排除项）。'), findsOneWidget);
  });
}
