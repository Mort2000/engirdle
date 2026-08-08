import '../../../contracts/catalog_v1/catalog.dart';
import '../../connection/application/connection_service.dart';
import '../../library/application/library_service.dart';
import '../domain/catalog_status.dart';

/// Catalog use cases. Results are session-scoped and never cached on disk
/// (design 假设③): leaving the bookshelf discards the remote view.
class CatalogService {
  CatalogService({
    required ConnectionService connection,
    required LibraryService library,
  })  : _connection = connection,
        _library = library;

  final ConnectionService _connection;
  final LibraryService _library;

  /// Fetches the catalog and merges it with local install state.
  Future<List<CatalogEntry>> checkForUpdates() async {
    final catalog = await _connection.checkForUpdates();
    return merge(catalog);
  }

  List<CatalogEntry> merge(Catalog catalog) {
    final installed = {
      for (final article in _library.listArticles()) article.articleId: article.ref,
    };
    return [
      for (final package in catalog.packages)
        CatalogEntry(
          package: package,
          status: statusOf(package, installed[package.articleId]),
        ),
    ];
  }
}
