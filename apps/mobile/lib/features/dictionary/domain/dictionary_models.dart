/// One candidate sense from the offline dictionary.
class DictionarySense {
  const DictionarySense({
    required this.senseId,
    required this.headword,
    required this.partOfSpeech,
    required this.glossEn,
    this.translations = const [],
    this.pronunciation,
    required this.sourceId,
    required this.sourceName,
  });

  final String senseId;
  final String headword;
  final String partOfSpeech;
  final String? glossEn;
  final List<DictionaryTranslation> translations;
  final String? pronunciation;
  final String sourceId;
  final String sourceName;

  String? get glossZh => translations.isEmpty
      ? null
      : translations.map((translation) => translation.displayLemma).join('；');
}

class DictionaryTranslation {
  const DictionaryTranslation({
    required this.sourceSenseId,
    required this.rawLemma,
    required this.displayLemma,
    required this.sourceId,
  });

  final String sourceSenseId;
  final String rawLemma;
  final String displayLemma;
  final String sourceId;
}

class DictionaryResult {
  const DictionaryResult({
    required this.surface,
    required this.normalized,
    this.lemma,
    this.senses = const [],
  });

  final String surface;
  final String normalized;
  final String? lemma;
  final List<DictionarySense> senses;
  bool get found => senses.isNotEmpty;
}

sealed class DictionaryLookup {
  const DictionaryLookup();
}

class DictionaryLookupUnavailable extends DictionaryLookup {
  const DictionaryLookupUnavailable(this.selection);
  final String selection;
}

class DictionaryLookupResourceError extends DictionaryLookup {
  const DictionaryLookupResourceError(this.selection, this.reason);
  final String selection;
  final String reason;
}

class DictionaryLookupNotFound extends DictionaryLookup {
  const DictionaryLookupNotFound(this.result);
  final DictionaryResult result;
}

class DictionaryLookupFound extends DictionaryLookup {
  const DictionaryLookupFound(this.result);
  final DictionaryResult result;
}

enum DictionaryResourceState {
  unavailable,
  installing,
  available,
  incompatible,
  corrupt,
}

class DictionaryStatus {
  const DictionaryStatus(this.state, {this.resource, this.message});

  final DictionaryResourceState state;
  final DictionaryResource? resource;
  final String? message;
}

class DictionaryPackageDescriptor {
  const DictionaryPackageDescriptor({
    required this.dictionaryId,
    required this.revision,
    required this.formatVersion,
    required this.schemaVersion,
    required this.displayName,
    required this.sizeBytes,
    required this.sha256,
  });

  final String dictionaryId;
  final int revision;
  final String formatVersion;
  final int schemaVersion;
  final String displayName;
  final int sizeBytes;
  final String sha256;
}

class DictionaryLicense {
  const DictionaryLicense({required this.name, required this.url});
  final String name;
  final Uri url;
}

class DictionaryAttribution {
  const DictionaryAttribution({required this.name, required this.url});
  final String name;
  final Uri url;
}

class DictionarySourceCounts {
  const DictionarySourceCounts({
    required this.originalHeadwords,
    required this.filteredHeadwords,
    required this.finalHeadwords,
  });

  final int originalHeadwords;
  final int filteredHeadwords;
  final int finalHeadwords;
}

class DictionarySource {
  const DictionarySource({
    required this.sourceId,
    required this.version,
    required this.displayName,
    required this.direction,
    required this.inputUrl,
    required this.inputSha256,
    required this.licenses,
    required this.attributions,
    required this.counts,
    required this.extractionNote,
  });

  final String sourceId;
  final String version;
  final String displayName;
  final String direction;
  final Uri inputUrl;
  final String inputSha256;
  final List<DictionaryLicense> licenses;
  final List<DictionaryAttribution> attributions;
  final DictionarySourceCounts counts;
  final String extractionNote;
}

class DictionaryResource {
  const DictionaryResource({
    required this.dictionaryId,
    required this.revision,
    required this.path,
    required this.sizeBytes,
    required this.sha256,
    required this.databaseSizeBytes,
    required this.databaseSha256,
    required this.formatVersion,
    required this.schemaVersion,
    required this.displayName,
    required this.generatedAt,
    required this.builderName,
    required this.builderVersion,
    required this.normalizationVersion,
    required this.sources,
    required this.modifications,
    required this.manifestJson,
  });

  final String dictionaryId;
  final int revision;
  final String path;
  final int sizeBytes;
  final String sha256;
  final int databaseSizeBytes;
  final String databaseSha256;
  final String formatVersion;
  final int schemaVersion;
  final String displayName;
  final String generatedAt;
  final String builderName;
  final String builderVersion;
  final String normalizationVersion;
  final List<DictionarySource> sources;
  final List<String> modifications;
  final String manifestJson;
}
