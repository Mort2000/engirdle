import 'dart:convert';

import 'package:engirdle_mobile/app/dependencies.dart';
import 'package:engirdle_mobile/app/router.dart';
import 'package:engirdle_mobile/features/importer/application/content_import_service.dart';
import 'package:engirdle_mobile/features/source_ingestion/domain/raw_source.dart';
import 'package:engirdle_mobile/features/library/presentation/bookshelf_page.dart';
import 'package:engirdle_mobile/shared_kernel/failures.dart';
import 'package:engirdle_mobile/features/source_ingestion/presentation/paste_source_page.dart';
import 'package:engirdle_mobile/features/source_ingestion/presentation/source_confirm_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_helpers.dart';

/// The phase-2 import UX: paste editor behavior (§6.2), confirmation page
/// gates (§6.3) and the bookshelf import panel with capability badges.
void main() {
  late AppDependencies deps;

  setUp(() async {
    deps = await newWidgetTestDependencies();
  });

  Widget host(Widget child) => wrapTestWidget(deps, child);

  testWidgets('paste page: byte counter, empty guard, preview flow installs', (
    tester,
  ) async {
    await tester.pumpWidget(host(const PasteSourcePage()));

    expect(find.text('预览'), findsOneWidget);
    // Empty body: the preview button stays disabled (§6.2).
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '预览'))
          .enabled,
      isFalse,
    );

    await tester.tap(find.text('Markdown'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '# Title\n\nBody text.');
    await tester.pump();
    expect(find.textContaining('字节（UTF-8）'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '预览'))
          .enabled,
      isTrue,
    );

    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(find.byType(SourceConfirmPage), findsOneWidget);
    final titleField = tester.widget<TextField>(
      find.widgetWithText(TextField, '标题（必填）'),
    );
    expect(titleField.controller!.text, 'Title');

    await tester.tap(find.widgetWithText(FilledButton, '确认导入'));
    await tester.pumpAndSettle();
    expect(deps.library.listArticles(), hasLength(1));
    expect(deps.library.listArticles().single.title, 'Title');
  });

  testWidgets('confirmation page: warnings require acknowledgement', (
    tester,
  ) async {
    final preview = await deps.contentImport.stageRawSource(
      rawBytes: utf8.encode('Intro.\n\n```\nunclosed'),
      syntax: SourceSyntax.markdown,
      origin: 'paste',
    );
    await tester.pumpWidget(host(SourceConfirmPage(preview: preview)));

    expect(find.textContaining('未闭合的代码围栏'), findsOneWidget);
    Future<bool> confirmEnabled() async {
      await tester.scrollUntilVisible(
        find.widgetWithText(FilledButton, '确认导入'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      return tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认导入'))
          .enabled;
    }

    expect(await confirmEnabled(), isFalse);
    await tester.scrollUntilVisible(
      find.text('我已确认上述警告符合预期'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('我已确认上述警告符合预期'));
    await tester.pump();
    expect(await confirmEnabled(), isTrue);
    await deps.contentImport.cancelRawSource(preview.importId);
  });

  testWidgets('confirmation page: back discards the preview', (tester) async {
    final preview = await deps.contentImport.stageRawSource(
      rawBytes: utf8.encode('Disposable body.'),
      syntax: SourceSyntax.plainText,
      origin: 'paste',
    );
    await tester.pumpWidget(host(SourceConfirmPage(preview: preview)));
    await tester.scrollUntilVisible(
      find.widgetWithText(OutlinedButton, '返回修改'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, '返回修改'));
    await tester.pumpAndSettle();
    expect(deps.library.listArticles(), isEmpty);
    // And the same import cannot be confirmed afterwards.
    expect(
      () => deps.contentImport.confirmRawSource(
        preview.importId,
        metadata: const ConfirmedSourceMetadata(
          title: 'X',
          licenseName: 'unknown',
        ),
      ),
      throwsA(isA<AppFailure>()),
    );
  });

  testWidgets('bookshelf: import panel opens paste first; file pick routes', (
    tester,
  ) async {
    deps.database.db.execute(
      "INSERT INTO service_config (id, base_url, verified_at, updated_at) "
      "VALUES (1, 'http://192.168.1.10:8000', '2026-08-01T00:00:00Z', "
      "'2026-08-01T00:00:00Z')",
    );
    await tester.pumpWidget(
      host(
        MaterialApp(
          onGenerateRoute: AppRoutes.onGenerateRoute,
          home: const BookshelfPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(find.text('粘贴原文'), findsWidgets);
    expect(find.text('选择原文文件'), findsOneWidget);
    expect(find.text('选择文章包'), findsOneWidget);

    await tester.tap(find.text('粘贴原文'));
    await tester.pumpAndSettle();
    expect(find.byType(PasteSourcePage), findsOneWidget);
  });

  testWidgets('bookshelf badges reflect capabilities', (tester) async {
    final preview = await deps.contentImport.stageRawSource(
      rawBytes: utf8.encode('Plain body only.'),
      syntax: SourceSyntax.plainText,
      origin: 'paste',
    );
    await deps.contentImport.confirmRawSource(
      preview.importId,
      metadata: const ConfirmedSourceMetadata(
        title: 'Badge article',
        licenseName: 'unknown',
      ),
    );
    deps.database.db.execute(
      "INSERT INTO service_config (id, base_url, verified_at, updated_at) "
      "VALUES (1, 'http://192.168.1.10:8000', '2026-08-01T00:00:00Z', "
      "'2026-08-01T00:00:00Z')",
    );
    await tester.pumpWidget(
      host(
        MaterialApp(
          onGenerateRoute: AppRoutes.onGenerateRoute,
          home: const BookshelfPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('原文'), findsOneWidget);
    expect(find.text('已翻译'), findsNothing);
  });
}
