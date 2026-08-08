/// Persisted LAN publisher configuration (MOB-NET-001).
class ServiceEndpoint {
  const ServiceEndpoint({
    required this.baseUrl,
    this.verifiedAt,
    this.lastCatalogCheckAt,
  });

  /// Normalized base URL, e.g. `http://192.168.1.12:8766` (no trailing slash).
  final Uri baseUrl;

  /// When the address last passed a catalog verification; null = never.
  final DateTime? verifiedAt;

  /// When the user last triggered "检查更新"; null = never.
  final DateTime? lastCatalogCheckAt;

  bool get isVerified => verifiedAt != null;

  Uri get catalogUrl => baseUrl.replace(path: '${baseUrl.path}/catalog.json');
}
