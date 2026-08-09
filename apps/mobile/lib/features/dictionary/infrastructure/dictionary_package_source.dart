import 'dart:io';

import '../../../platform/http/lan_http_client.dart';
import '../domain/dictionary_models.dart';

abstract interface class DictionaryPackageSource {
  DictionaryPackageDescriptor get descriptor;

  Future<void> copyTo(
    File target, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    CancelToken? cancelToken,
  });
}

class LocalDictionaryPackageSource implements DictionaryPackageSource {
  const LocalDictionaryPackageSource({
    required this.descriptor,
    required this.package,
  });

  @override
  final DictionaryPackageDescriptor descriptor;
  final File package;

  @override
  Future<void> copyTo(
    File target, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    CancelToken? cancelToken,
  }) async {
    await target.parent.create(recursive: true);
    final sink = target.openWrite();
    var received = 0;
    try {
      await for (final chunk in package.openRead()) {
        if (cancelToken?.isCancelled ?? false) {
          throw const FileSystemException('dictionary copy cancelled');
        }
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, descriptor.sizeBytes);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }
}

class LanDictionaryPackageSource implements DictionaryPackageSource {
  const LanDictionaryPackageSource({
    required this.descriptor,
    required this.url,
    required LanHttpClient httpClient,
  }) : _httpClient = httpClient;

  @override
  final DictionaryPackageDescriptor descriptor;
  final Uri url;
  final LanHttpClient _httpClient;

  @override
  Future<void> copyTo(
    File target, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    CancelToken? cancelToken,
  }) => _httpClient.downloadToFile(
    url,
    target,
    maxBytes: descriptor.sizeBytes,
    onProgress: onProgress,
    cancelToken: cancelToken,
  );
}
