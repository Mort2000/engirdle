import '../../shared_kernel/content_identity.dart';
import '../contract_violation.dart';

/// Catalog v1 (`/catalog.json`) with its semantic rules (COMPATIBILITY.md):
/// reject malformed entries, unsafe or cross-origin URLs, duplicate
/// article_ids, duplicate URLs and unsupported readpack major versions.
class Catalog {
  const Catalog({
    required this.catalogVersion,
    required this.generatedAt,
    required this.packages,
    this.dictionaries = const [],
  });

  final int catalogVersion;
  final String generatedAt;
  final List<CatalogPackage> packages;
  final List<CatalogDictionary> dictionaries;

  static final _relativeUrlPattern = RegExp(
    r'^/packages/[A-Za-z0-9][A-Za-z0-9._-]{0,199}\.readpack$',
  );
  static final _absolutePathPattern = RegExp(
    r'^/packages/[A-Za-z0-9][A-Za-z0-9._-]{0,199}\.readpack$',
  );
  static final _relativeDictionaryUrlPattern = RegExp(
    r'^/dictionaries/[A-Za-z0-9][A-Za-z0-9._-]{0,199}\.dictpack$',
  );
  static final _absoluteDictionaryPathPattern = RegExp(
    r'^/dictionaries/[A-Za-z0-9][A-Za-z0-9._-]{0,199}\.dictpack$',
  );

  /// [origin] is the URL the catalog itself was fetched from; absolute
  /// package URLs must be same-origin with it (fixture: cross-origin-url).
  static Catalog parse(Object? json, {required Uri origin}) {
    final r = JsonReader(json, 'catalog');
    final packageReaders = r['packages'].asArray(maxItems: 100000);
    final packages = <CatalogPackage>[];
    final articleIds = <String>{};
    final urls = <String>{};
    for (var i = 0; i < packageReaders.length; i++) {
      final p = packageReaders[i];
      final articleId = p['article_id'].uuid();
      if (!articleIds.add(articleId)) {
        throw ContractViolation(
          'catalog.packages[$i].article_id',
          'duplicate article',
        );
      }
      final url = _validateUrl(
        p['url'],
        origin,
        relativePattern: _relativeUrlPattern,
        absolutePathPattern: _absolutePathPattern,
      );
      if (!urls.add(url.toString())) {
        throw ContractViolation('catalog.packages[$i].url', 'duplicate url');
      }
      packages.add(
        CatalogPackage(
          articleId: articleId,
          revision: p['revision'].positiveInt(),
          artifactRevision: p['artifact_revision'].positiveInt(),
          title: p['title'].asString(minLength: 1, maxLength: 512),
          formatVersion: p['format_version'].v1Version(),
          size: p['size'].asInt(min: 1, max: 536870912),
          sha256: p['sha256'].sha256(),
          url: url,
        ),
      );
    }
    final dictionaryReaders =
        r.optional('dictionaries')?.asArray(maxItems: 16) ?? const [];
    final dictionaries = <CatalogDictionary>[];
    final dictionaryIds = <String>{};
    for (var i = 0; i < dictionaryReaders.length; i++) {
      final dictionary = dictionaryReaders[i];
      final dictionaryId = dictionary['dictionary_id'].opaqueId();
      if (!dictionaryIds.add(dictionaryId)) {
        throw ContractViolation(
          'catalog.dictionaries[$i].dictionary_id',
          'duplicate dictionary',
        );
      }
      final url = _validateUrl(
        dictionary['url'],
        origin,
        relativePattern: _relativeDictionaryUrlPattern,
        absolutePathPattern: _absoluteDictionaryPathPattern,
      );
      if (!urls.add(url.toString())) {
        throw ContractViolation(
          'catalog.dictionaries[$i].url',
          'duplicate url',
        );
      }
      dictionaries.add(
        CatalogDictionary(
          dictionaryId: dictionaryId,
          revision: dictionary['revision'].positiveInt(),
          formatVersion: dictionary['format_version'].v1Version(),
          schemaVersion: dictionary['schema_version'].positiveInt(),
          displayName: dictionary['display_name'].asString(
            minLength: 1,
            maxLength: 256,
          ),
          size: dictionary['size'].asInt(min: 1, max: 536870912),
          sha256: dictionary['sha256'].sha256(),
          url: url,
        ),
      );
    }
    return Catalog(
      catalogVersion: r['catalog_version'].asInt(min: 1, max: 9007199254740991),
      generatedAt: r['generated_at'].dateTime(),
      packages: packages,
      dictionaries: dictionaries,
    );
  }

  /// Validates the package URL shape and origin, returning a fetchable URL.
  static Uri _validateUrl(
    JsonReader r,
    Uri origin, {
    required RegExp relativePattern,
    required RegExp absolutePathPattern,
  }) {
    final raw = r.asString(maxLength: 2048);
    if (raw.startsWith('/')) {
      if (!relativePattern.hasMatch(raw)) {
        throw ContractViolation(r.path, 'unsafe url');
      }
      return origin.replace(path: raw, query: null, fragment: null);
    }
    // The schema pattern anchors absolute URLs on a lowercase scheme
    // (`^https?://`, case-sensitive); Dart's Uri normalizes the scheme to
    // lowercase, so compare the raw string before parsing.
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      throw ContractViolation(r.path, 'unsafe url');
    }
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      throw ContractViolation(r.path, 'unsafe url');
    }
    if (!absolutePathPattern.hasMatch(uri.path)) {
      throw ContractViolation(r.path, 'unsafe url path');
    }
    final sameOrigin =
        uri.scheme == origin.scheme &&
        uri.host.toLowerCase() == origin.host.toLowerCase() &&
        _portOf(uri) == _portOf(origin);
    if (!sameOrigin) {
      throw ContractViolation(r.path, 'cross-origin url');
    }
    return uri;
  }

  static int _portOf(Uri uri) =>
      uri.hasPort ? uri.port : (uri.isScheme('https') ? 443 : 80);
}

class CatalogDictionary {
  const CatalogDictionary({
    required this.dictionaryId,
    required this.revision,
    required this.formatVersion,
    required this.schemaVersion,
    required this.displayName,
    required this.size,
    required this.sha256,
    required this.url,
  });

  final String dictionaryId;
  final int revision;
  final String formatVersion;
  final int schemaVersion;
  final String displayName;
  final int size;
  final String sha256;
  final Uri url;
}

class CatalogPackage {
  const CatalogPackage({
    required this.articleId,
    required this.revision,
    required this.artifactRevision,
    required this.title,
    required this.formatVersion,
    required this.size,
    required this.sha256,
    required this.url,
  });

  final String articleId;
  final int revision;
  final int artifactRevision;
  final String title;
  final String formatVersion;
  final int size;
  final String sha256;
  final Uri url;

  ArticleRef get ref => ArticleRef(
    articleId: articleId,
    revision: revision,
    artifactRevision: artifactRevision,
  );
}
