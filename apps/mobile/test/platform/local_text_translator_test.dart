import 'package:engirdle_mobile/platform/translation/local_text_translator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.engirdle.mobile/text_processing');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('passes the exact selection to the Android text processor', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return true;
        });

    final result = await const MethodChannelLocalTextTranslator().translate(
      '  take off  ',
    );

    expect(result, LocalTranslationResult.opened);
    expect(received?.method, 'translate');
    expect(received?.arguments, {'text': '  take off  '});
  });

  test('reports that no local processor is installed', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false);

    expect(
      await const MethodChannelLocalTextTranslator().translate('word'),
      LocalTranslationResult.unavailable,
    );
  });
}
