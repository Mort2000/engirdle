import 'dart:convert';

import '../../../contracts/readpack_v1/attribution.dart';
import '../../../contracts/readpack_v1/manifest.dart';
import '../../dictionary/application/dictionary_service.dart';
import '../../dictionary/domain/dictionary_models.dart';
import '../../library/application/library_service.dart';

/// Assembles the attribution page data (NFR-LIC-001, screen 15):
/// the package's own attribution chain plus the independently versioned
/// dictionary resource. Unknown fields are shown explicitly, never blanked.
class AttributionService {
  AttributionService({
    required LibraryService library,
    required DictionaryService dictionary,
  })  : _library = library,
        _dictionary = dictionary;

  final LibraryService _library;
  final DictionaryService _dictionary;

  /// Parses the stored manifest/attribution for [articleId]; null when the
  /// article is not installed.
  ({ReadpackManifest manifest, ReadpackAttribution attribution})?
      articleAttribution(String articleId) {
    final raw = _library.getAttributionJson(articleId);
    if (raw == null) return null;
    return (
      manifest: ReadpackManifest.parse(jsonDecode(raw.manifestJson)),
      attribution: ReadpackAttribution.parse(jsonDecode(raw.attributionJson)),
    );
  }

  DictionaryResource? dictionaryResource() => _dictionary.currentResource();
}
