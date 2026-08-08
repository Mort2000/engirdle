import 'package:sqlite3/sqlite3.dart';

import '../domain/service_endpoint.dart';

/// DAO for the `service_config` table (owned by the connection feature).
class ServiceConfigDao {
  const ServiceConfigDao(this._db);

  final Database _db;

  static const _cols = 'base_url, verified_at, last_catalog_check_at';

  ServiceEndpoint? load() {
    final rows = _db.select('SELECT $_cols FROM service_config WHERE id = 1');
    if (rows.isEmpty) return null;
    final row = rows.first;
    final baseUrl = row['base_url'] as String?;
    if (baseUrl == null) return null;
    return ServiceEndpoint(
      baseUrl: Uri.parse(baseUrl),
      verifiedAt: _parseTime(row['verified_at'] as String?),
      lastCatalogCheckAt: _parseTime(row['last_catalog_check_at'] as String?),
    );
  }

  void save(ServiceEndpoint endpoint) {
    final now = DateTime.now().toUtc().toIso8601String();
    _db.execute(
      'INSERT INTO service_config (id, base_url, verified_at, '
      'last_catalog_check_at, updated_at) VALUES (1, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET base_url = excluded.base_url, '
      'verified_at = excluded.verified_at, '
      'last_catalog_check_at = excluded.last_catalog_check_at, '
      'updated_at = excluded.updated_at',
      [
        endpoint.baseUrl.toString(),
        endpoint.verifiedAt?.toUtc().toIso8601String(),
        endpoint.lastCatalogCheckAt?.toUtc().toIso8601String(),
        now,
      ],
    );
  }

  static DateTime? _parseTime(String? value) =>
      value == null ? null : DateTime.tryParse(value)?.toLocal();
}
