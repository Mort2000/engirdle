import 'package:engirdle_mobile/app/app.dart';
import 'package:engirdle_mobile/app/dependencies.dart';
import 'package:engirdle_mobile/features/dictionary/domain/dictionary_models.dart';
import 'package:engirdle_mobile/features/preferences/presentation/typography_settings_page.dart';
import 'package:engirdle_mobile/features/preferences/presentation/playback_settings_page.dart';
import 'package:engirdle_mobile/features/dictionary/presentation/dictionary_resources_page.dart';
import 'package:engirdle_mobile/features/vocabulary/presentation/vocab_book_page.dart';
import 'package:engirdle_mobile/platform/http/lan_http_client.dart';
import 'package:flutter/material.dart';
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
    deps = await newTestDependencies(httpClient: _CatalogHttpClient());
  });

  testWidgets('first run opens the bookshelf then routes to service setup', (
    tester,
  ) async {
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
    await tester.pumpWidget(
      wrapTestWidget(deps, const TypographySettingsPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('排版与主题'), findsWidgets);
    expect(find.text('仅提供预设主题，不提供自定义取色器（MVP 排除项）。'), findsOneWidget);
  });

  testWidgets('playback settings toggle background music interruption', (
    tester,
  ) async {
    await tester.pumpWidget(wrapTestWidget(deps, const PlaybackSettingsPage()));
    await tester.pumpAndSettle();

    expect(find.text('播放设置'), findsOneWidget);
    expect(find.text('播放时打断背景音乐'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );

    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();

    expect(deps.preferences.interruptBackgroundAudio, isFalse);
  });

  testWidgets(
    'dictionary resources page distinguishes an uninstalled resource',
    (tester) async {
      await tester.pumpWidget(
        wrapTestWidget(deps, const DictionaryResourcesPage()),
      );
      await tester.pumpAndSettle();

      expect(find.text('词典资源'), findsWidgets);
      expect(find.text('未安装'), findsOneWidget);
      expect(find.textContaining('阅读、翻译、播放和生词本仍可使用'), findsOneWidget);
      expect(find.text('检查可用资源'), findsOneWidget);
    },
  );

  testWidgets('a corrupt dictionary can reinstall the same revision', (
    tester,
  ) async {
    deps.connection.saveUrl('http://127.0.0.1:8080');
    deps.dictionary.status.value = DictionaryStatus(
      DictionaryResourceState.corrupt,
      resource: _dictionaryResource,
      message: 'dictionary query failed',
    );
    await tester.pumpWidget(
      wrapTestWidget(deps, const DictionaryResourcesPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('损坏'), findsOneWidget);

    await tester.tap(find.text('检查可用资源'));
    await tester.pumpAndSettle();

    final reinstall = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '重装'),
    );
    expect(reinstall.onPressed, isNotNull);
  });
}

final _dictionaryResource = DictionaryResource(
  dictionaryId: 'engirdle-en-zh',
  revision: 2,
  path: '/missing/dictionary.db',
  sizeBytes: 1024,
  sha256: '0' * 64,
  databaseSizeBytes: 512,
  databaseSha256: '1' * 64,
  formatVersion: '2.0',
  schemaVersion: 2,
  displayName: 'Engirdle Offline Dictionary',
  generatedAt: '2026-08-09T00:00:00Z',
  builderName: 'test',
  builderVersion: '1.0.0',
  normalizationVersion: 'unicode-nfc-lower-v1',
  sources: [],
  modifications: [],
  manifestJson: '{}',
);

class _CatalogHttpClient extends LanHttpClient {
  @override
  Future<Object> getJson(
    Uri uri, {
    int maxBytes = LanHttpClient.maxJsonBytes,
  }) async => {
    'catalog_version': 1,
    'generated_at': '2026-08-09T00:00:00Z',
    'packages': <Object>[],
    'dictionaries': [
      {
        'dictionary_id': 'engirdle-en-zh',
        'revision': 2,
        'format_version': '2.0',
        'schema_version': 2,
        'display_name': 'Engirdle Offline Dictionary',
        'size': 1024,
        'sha256': '0' * 64,
        'url': '/dictionaries/engirdle-en-zh-r2-test.dictpack',
      },
    ],
  };
}
