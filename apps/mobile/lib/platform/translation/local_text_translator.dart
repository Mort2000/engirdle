import 'package:flutter/services.dart';

enum LocalTranslationResult { opened, unavailable }

abstract interface class LocalTextTranslator {
  Future<LocalTranslationResult> translate(String text);
}

class MethodChannelLocalTextTranslator implements LocalTextTranslator {
  const MethodChannelLocalTextTranslator();

  static const _channel = MethodChannel('com.engirdle.mobile/text_processing');

  @override
  Future<LocalTranslationResult> translate(String text) async {
    final opened = await _channel.invokeMethod<bool>('translate', {
      'text': text,
    });
    return opened == true
        ? LocalTranslationResult.opened
        : LocalTranslationResult.unavailable;
  }
}
