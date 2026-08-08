import 'dart:io';

import 'package:crypto/crypto.dart';

/// Streams [file] through SHA-256 without loading it into memory.
Future<String> sha256OfFile(File file) async {
  final sink = _DigestCollector();
  final input = sha256.startChunkedConversion(sink);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  return sink.value!.toString();
}

/// Collects the single digest produced by a chunked hash conversion.
class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest digest) => value = digest;

  @override
  void close() {}
}
