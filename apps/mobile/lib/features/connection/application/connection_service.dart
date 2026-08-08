import '../../../contracts/catalog_v1/catalog.dart';
import '../../../contracts/contract_violation.dart';
import '../../../platform/http/lan_http_client.dart';
import '../../../shared_kernel/failures.dart';
import '../domain/service_endpoint.dart';
import '../infrastructure/service_config_dao.dart';

/// Use cases for configuring and verifying the LAN publisher.
class ConnectionService {
  ConnectionService({
    required ServiceConfigDao dao,
    required LanHttpClient httpClient,
  })  : _dao = dao,
        _http = httpClient;

  final ServiceConfigDao _dao;
  final LanHttpClient _http;

  ServiceEndpoint? current() => _dao.load();

  /// Validates the URL (format + LAN policy, before any request) and saves.
  ///
  /// Saving without verifying is allowed (screen 01); the catalog page then
  /// asks the user to verify first. A new URL invalidates prior verification.
  ServiceEndpoint saveUrl(String input) {
    final uri = LanHttpClient.normalizeServiceUrl(input);
    final previous = _dao.load();
    final endpoint = ServiceEndpoint(
      baseUrl: uri,
      verifiedAt:
          previous != null && previous.baseUrl == uri ? previous.verifiedAt : null,
      lastCatalogCheckAt: previous?.lastCatalogCheckAt,
    );
    _dao.save(endpoint);
    return endpoint;
  }

  /// Verifies by fetching `/catalog.json`; returns the validated catalog.
  ///
  /// Success persists `verified_at` and `last_catalog_check_at`.
  Future<Catalog> verify() async {
    final endpoint = _requireEndpoint();
    final catalog = await _fetchCatalog(endpoint);
    _dao.save(ServiceEndpoint(
      baseUrl: endpoint.baseUrl,
      verifiedAt: DateTime.now(),
      lastCatalogCheckAt: endpoint.lastCatalogCheckAt,
    ));
    return catalog;
  }

  /// Fetches the catalog for a "检查更新" cycle. Updates the last-check time
  /// only on success; the result itself is never cached (design 假设③).
  Future<Catalog> checkForUpdates() async {
    final endpoint = _requireEndpoint();
    final catalog = await _fetchCatalog(endpoint);
    _dao.save(ServiceEndpoint(
      baseUrl: endpoint.baseUrl,
      verifiedAt: endpoint.verifiedAt ?? DateTime.now(),
      lastCatalogCheckAt: DateTime.now(),
    ));
    return catalog;
  }

  Future<Catalog> _fetchCatalog(ServiceEndpoint endpoint) async {
    final json = await _http.getJson(endpoint.catalogUrl);
    try {
      return Catalog.parse(json, origin: endpoint.baseUrl);
    } on ContractViolation catch (e) {
      throw AppFailure(FailureKind.connection, 'invalid catalog',
          detail: e.toString());
    }
  }

  ServiceEndpoint _requireEndpoint() {
    final endpoint = _dao.load();
    if (endpoint == null) {
      throw const AppFailure(FailureKind.connection, 'service not configured');
    }
    return endpoint;
  }
}
