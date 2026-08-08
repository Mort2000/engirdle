import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../shared_kernel/failures.dart';

/// Cooperative cancellation for in-flight requests.
class CancelToken {
  bool _cancelled = false;
  final _completer = Completer<void>();

  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// HTTP client for the user-configured LAN publisher (design §7).
///
/// Policy (screen 02B, MOB-NET-001):
/// - URLs must be absolute `http://` or `https://`;
/// - cleartext HTTP is only allowed to LAN addresses (private/loopback IPv4
///   literals or `localhost`); anything else is rejected **before** any
///   network request is made;
/// - HTTPS is supported normally;
/// - every request has a finite timeout and a maximum response size.
class LanHttpClient {
  LanHttpClient({this.timeout = const Duration(seconds: 8)});

  /// Finite timeout for connect, response and per-chunk stalls.
  final Duration timeout;

  /// Max bytes accepted for a JSON document (catalog) response.
  static const maxJsonBytes = 4 * 1024 * 1024;

  /// Max package size accepted while downloading (design §6.5 candidate).
  static const maxPackageBytes = 512 * 1024 * 1024;

  /// Normalizes and validates a service base URL typed by the user.
  ///
  /// Returns the normalized [Uri] (no trailing slash) on success; throws
  /// [AppFailure] with [FailureKind.connection] on any policy violation.
  static Uri normalizeServiceUrl(String input) {
    final trimmed = input.trim();
    final uri = trimmed.isEmpty ? null : Uri.tryParse(trimmed);
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const AppFailure(
        FailureKind.connection,
        'invalid url',
        detail: 'must start with http:// or https://',
      );
    }
    if (uri.isScheme('http') && !_isLanHost(uri.host)) {
      throw const AppFailure(
        FailureKind.connection,
        'non-lan http rejected',
        detail: 'cleartext HTTP is limited to LAN addresses; use HTTPS',
      );
    }
    // Normalize: scheme://host[:port] + path without trailing slash.
    final path = uri.path.endsWith('/')
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    return Uri(
      scheme: uri.scheme.toLowerCase(),
      host: uri.host.toLowerCase(),
      port: uri.hasPort ? uri.port : null,
      path: path.isEmpty ? null : path,
    );
  }

  /// True when [host] is a loopback/private IPv4 literal or localhost.
  static bool _isLanHost(String host) {
    final lower = host.toLowerCase();
    if (lower == 'localhost') return true;
    final v4 = InternetAddress.tryParse(lower);
    if (v4 == null || v4.type != InternetAddressType.IPv4) return false;
    final b = v4.rawAddress;
    if (b[0] == 10) return true; // 10.0.0.0/8
    if (b[0] == 127) return true; // 127.0.0.0/8 loopback
    if (b[0] == 169 && b[1] == 254) return true; // link-local
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true; // 172.16.0.0/12
    if (b[0] == 192 && b[1] == 168) return true; // 192.168.0.0/16
    return false;
  }

  /// GETs [uri] and decodes it as a JSON UTF-8 document.
  ///
  /// Rejects responses larger than [maxBytes]. Throws [AppFailure] with
  /// [FailureKind.connection] on network errors.
  Future<Object> getJson(Uri uri, {int maxBytes = maxJsonBytes}) async {
    final client = _newClient();
    try {
      final response = await _open(client, uri, null);
      _requireOk(response);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          throw const AppFailure(
              FailureKind.connection, 'response too large');
        }
      }
      final bytes = builder.takeBytes();
      try {
        return jsonDecode(utf8.decode(bytes)) as Object;
      } on FormatException {
        throw const AppFailure(FailureKind.connection, 'invalid json response');
      }
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      throw const AppFailure(FailureKind.connection, 'timeout',
          detail: 'response stalled');
    } on SocketException catch (e) {
      throw AppFailure(FailureKind.connection, _socketReason(e),
          detail: e.message);
    } on HttpException catch (e) {
      throw AppFailure(FailureKind.connection, 'http error',
          detail: e.message);
    } finally {
      client.close(force: true);
    }
  }

  /// Streams [uri] to [target], reporting progress via [onProgress].
  ///
  /// Enforces [maxBytes] while writing (never trusts declared lengths alone).
  /// Throws [AppFailure] with [FailureKind.download] on transfer problems.
  /// A cancelled download always removes its partial file.
  Future<void> downloadToFile(
    Uri uri,
    File target, {
    int maxBytes = maxPackageBytes,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final client = _newClient();
    IOSink? sink;
    var completed = false;
    try {
      final response = await _open(client, uri, cancelToken);
      _requireOk(response);
      final declared =
          response.contentLength >= 0 ? response.contentLength : null;
      if (declared != null && declared > maxBytes) {
        throw const AppFailure(FailureKind.download, 'package too large');
      }
      await target.parent.create(recursive: true);
      sink = target.openWrite();
      var received = 0;
      await for (final chunk in response.timeout(timeout)) {
        if (cancelToken?.isCancelled ?? false) {
          throw const AppFailure(FailureKind.download, 'cancelled');
        }
        received += chunk.length;
        if (received > maxBytes) {
          throw const AppFailure(FailureKind.download, 'package too large');
        }
        sink.add(chunk);
        onProgress?.call(received, declared);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      completed = true;
      onProgress?.call(received, declared);
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      throw const AppFailure(FailureKind.download, 'timeout');
    } on SocketException catch (e) {
      throw AppFailure(FailureKind.download, 'network error',
          detail: e.message);
    } on HttpException catch (e) {
      throw AppFailure(FailureKind.download, 'http error', detail: e.message);
    } on FileSystemException catch (e) {
      // Disk-side failures (flush/close of the target file) are download
      // failures too: the transfer did not produce a usable file.
      throw AppFailure(FailureKind.download, 'file write failed',
          detail: e.message);
    } finally {
      // Best-effort: a failing close here must not mask the failure above.
      try {
        await sink?.close();
      } catch (_) {
        // Ignored; the original failure is already propagating.
      }
      client.close(force: true);
      if (!completed && await target.exists()) {
        await target.delete();
      }
    }
  }

  HttpClient _newClient() => HttpClient()..connectionTimeout = timeout;

  Future<HttpClientResponse> _open(
    HttpClient client,
    Uri uri,
    CancelToken? cancelToken,
  ) async {
    // Check before touching the network: a pre-cancelled token must not
    // issue a request at all.
    if (cancelToken?.isCancelled ?? false) {
      throw const AppFailure(FailureKind.download, 'cancelled');
    }
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      // Never follow redirects: a 302 could bounce a cleartext-LAN-approved
      // request to an arbitrary (or plaintext-downgraded) location. The
      // read-only PC service has no legitimate redirects, so 3xx responses
      // fall through to _requireOk and are rejected as connection errors.
      request.followRedirects = false;
      cancelToken?.whenCancelled.then((_) => request.abort());
      return await request.close().timeout(timeout);
    } on TimeoutException {
      throw const AppFailure(FailureKind.connection, 'timeout',
          detail: 'no response within deadline');
    } on SocketException catch (e) {
      throw AppFailure(FailureKind.connection, _socketReason(e),
          detail: e.message);
    } on HttpException catch (e) {
      // request.abort() surfaces as a 'Request has been aborted'
      // HttpException; report the real cause when the token was cancelled.
      if (cancelToken?.isCancelled ?? false) {
        throw const AppFailure(FailureKind.download, 'cancelled');
      }
      throw AppFailure(FailureKind.connection, 'http error',
          detail: e.message);
    }
  }

  static String _socketReason(SocketException e) {
    final msg = e.message.toLowerCase();
    if (msg.contains('refused')) return 'connection refused';
    if (msg.contains('host') || msg.contains('name')) return 'host unreachable';
    if (msg.contains('network')) return 'network unreachable';
    return 'network error';
  }

  static void _requireOk(HttpClientResponse response) {
    final status = response.statusCode;
    if (status < 200 || status >= 300) {
      throw AppFailure(FailureKind.connection, 'http $status');
    }
  }
}
