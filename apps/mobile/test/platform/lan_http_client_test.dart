import 'dart:io';

import 'package:engirdle_mobile/platform/http/lan_http_client.dart';
import 'package:engirdle_mobile/shared_kernel/failures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// LAN URL policy and transfer limits (MOB-NET-001, screen 02B).
void main() {
  group('normalizeServiceUrl', () {
    test('accepts private IPv4, loopback and localhost over http', () {
      for (final url in [
        'http://192.168.1.20:8766',
        'http://10.0.0.5:8766',
        'http://172.16.3.4',
        'http://172.31.255.1',
        'http://127.0.0.1:8766',
        'http://localhost:8766',
        'http://169.254.1.1',
      ]) {
        expect(LanHttpClient.normalizeServiceUrl(url).host, isNotEmpty,
            reason: url);
      }
      final uri = LanHttpClient.normalizeServiceUrl('http://192.168.1.20:8766');
      expect(uri.scheme, 'http');
      expect(uri.host, '192.168.1.20');
      expect(uri.port, 8766);
    });

    test('rejects cleartext http to non-LAN hosts before any request', () {
      for (final url in [
        'http://8.8.8.8',
        'http://192.0.2.10:8766', // TEST-NET-1: not a private range
        'http://example.com',
      ]) {
        expect(
          () => LanHttpClient.normalizeServiceUrl(url),
          throwsA(isA<AppFailure>()
              .having((f) => f.kind, 'kind', FailureKind.connection)
              .having((f) => f.message, 'message', 'non-lan http rejected')),
          reason: url,
        );
      }
    });

    test('accepts https to any host', () {
      expect(LanHttpClient.normalizeServiceUrl('https://example.com').host,
          'example.com');
    });

    test('rejects malformed input and credentials', () {
      for (final url in [
        '',
        'example.com',
        'ftp://192.168.1.1',
        'http://user:pass@192.168.1.1',
        'http://192.168.1.1/path?x=1',
      ]) {
        expect(() => LanHttpClient.normalizeServiceUrl(url),
            throwsA(isA<AppFailure>()),
            reason: url);
      }
    });

    test('strips a trailing slash', () {
      final uri =
          LanHttpClient.normalizeServiceUrl('http://192.168.1.1:8766/api/');
      expect(uri.path, '/api');
    });
  });

  group('transfers against a local server', () {
    late HttpServer server;
    late Directory temp;
    final client = LanHttpClient(timeout: const Duration(seconds: 5));

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('lan_http_test_');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        final response = request.response;
        switch (request.uri.path) {
          case '/ok.json':
            response.headers.contentType = ContentType.json;
            response.write('{"hello":"world"}');
          case '/not-found':
            response.statusCode = 404;
          case '/redirect':
            // A 302 must never be followed (redirects could escape the
            // cleartext-LAN policy or downgrade HTTPS to plaintext).
            response.statusCode = 302;
            response.headers.set(HttpHeaders.locationHeader, '/ok.json');
          case '/package':
            final bytes = List<int>.generate(4096, (i) => i % 253);
            response.headers.contentLength = bytes.length;
            response.add(bytes);
          default:
            response.statusCode = 500;
        }
        response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    Uri url(String path) =>
        Uri.parse('http://127.0.0.1:${server.port}$path');

    test('getJson parses a JSON document', () async {
      final json = await client.getJson(url('/ok.json'));
      expect((json as Map)['hello'], 'world');
    });

    test('getJson maps http errors to connection failures', () async {
      await expectLater(
        client.getJson(url('/not-found')),
        throwsA(isA<AppFailure>()
            .having((f) => f.kind, 'kind', FailureKind.connection)
            .having((f) => f.message, 'message', 'http 404')),
      );
    });

    test('redirects are not followed and rejected as connection errors',
        () async {
      await expectLater(
        client.getJson(url('/redirect')),
        throwsA(isA<AppFailure>()
            .having((f) => f.kind, 'kind', FailureKind.connection)
            .having((f) => f.message, 'message', 'http 302')),
      );
      // Same for downloads: the 3xx is refused before any file is created.
      final target = File(p.join(temp.path, 'pkg.readpack'));
      await expectLater(
        client.downloadToFile(url('/redirect'), target),
        throwsA(isA<AppFailure>()
            .having((f) => f.kind, 'kind', FailureKind.connection)
            .having((f) => f.message, 'message', 'http 302')),
      );
      expect(await target.exists(), isFalse);
    });

    test('getJson enforces the response size limit', () async {
      await expectLater(
        client.getJson(url('/ok.json'), maxBytes: 4),
        throwsA(isA<AppFailure>()
            .having((f) => f.message, 'message', 'response too large')),
      );
    });

    test('downloadToFile writes bytes and reports progress', () async {
      final target = File(p.join(temp.path, 'pkg.readpack'));
      final progress = <(int, int?)>[];
      await client.downloadToFile(url('/package'), target,
          onProgress: (received, total) => progress.add((received, total)));
      expect(await target.length(), 4096);
      expect(progress, isNotEmpty);
      expect(progress.last, (4096, 4096));
    });

    test('downloadToFile enforces the package size limit', () async {
      final target = File(p.join(temp.path, 'pkg.readpack'));
      await expectLater(
        client.downloadToFile(url('/package'), target, maxBytes: 100),
        throwsA(isA<AppFailure>()
            .having((f) => f.kind, 'kind', FailureKind.download)
            .having((f) => f.message, 'message', 'package too large')),
      );
      // Partial files are always removed.
      expect(await target.exists(), isFalse);
    });

    test('a cancelled download removes its partial file', () async {
      final target = File(p.join(temp.path, 'pkg.readpack'));
      final token = CancelToken()..cancel();
      await expectLater(
        client.downloadToFile(url('/package'), target, cancelToken: token),
        throwsA(isA<AppFailure>()
            .having((f) => f.message, 'message', 'cancelled')),
      );
      expect(await target.exists(), isFalse);
    });

    test('getJson maps refused connections to connection failures', () async {
      final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      await expectLater(
        client.getJson(Uri.parse('http://127.0.0.1:$port/ok.json')),
        throwsA(isA<AppFailure>()
            .having((f) => f.kind, 'kind', FailureKind.connection)),
      );
    });
  });
}
