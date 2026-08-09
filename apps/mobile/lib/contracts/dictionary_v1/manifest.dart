import 'dart:convert';

import '../../features/dictionary/domain/dictionary_models.dart';
import '../contract_violation.dart';

class DictionaryManifest {
  const DictionaryManifest({
    required this.formatVersion,
    required this.dictionaryId,
    required this.revision,
    required this.schemaVersion,
    required this.displayName,
    required this.generatedAt,
    required this.builderName,
    required this.builderVersion,
    required this.normalizationVersion,
    required this.databaseSize,
    required this.databaseSha256,
    required this.sources,
    required this.modifications,
    required this.licenseFiles,
  });

  static const supportedDictionaryId = 'engirdle-en-zh';
  static const supportedSchemaVersion = 1;
  static const supportedNormalizationVersion = 'unicode-nfc-lower-v1';
  static const requiredSourceIds = {'oewn-2025', 'freedict-eng-zho-2025.11.23'};

  final String formatVersion;
  final String dictionaryId;
  final int revision;
  final int schemaVersion;
  final String displayName;
  final String generatedAt;
  final String builderName;
  final String builderVersion;
  final String normalizationVersion;
  final int databaseSize;
  final String databaseSha256;
  final List<DictionarySource> sources;
  final List<String> modifications;
  final List<String> licenseFiles;

  static DictionaryManifest parse(Object? json) {
    final r = JsonReader(json, 'manifest');
    final formatVersion = r['format_version'].v1Version();
    final dictionaryId = r['dictionary_id'].opaqueId();
    if (dictionaryId != supportedDictionaryId) {
      throw ContractViolation(
        r['dictionary_id'].path,
        'unsupported dictionary id',
      );
    }
    final schemaVersion = r['schema_version'].positiveInt();
    if (schemaVersion != supportedSchemaVersion) {
      throw ContractViolation(
        r['schema_version'].path,
        'unsupported schema version',
      );
    }
    final builder = r['builder'];
    final normalization = r['normalization'];
    final normalizationVersion = normalization['version'].asString(
      minLength: 1,
      maxLength: 128,
    );
    if (normalizationVersion != supportedNormalizationVersion) {
      throw ContractViolation(
        normalization['version'].path,
        'unsupported normalization version',
      );
    }
    final database = r['database'];
    database['path'].mustEqual('dictionary.db', 'database path');
    final sourceReaders = r['sources'].asArray(minItems: 2, maxItems: 2);
    final sources = <DictionarySource>[];
    final sourceIds = <String>{};
    for (var index = 0; index < sourceReaders.length; index++) {
      final source = sourceReaders[index];
      final sourceId = source['source_id'].opaqueId();
      if (!sourceIds.add(sourceId)) {
        throw ContractViolation(
          source['source_id'].path,
          'duplicate source id',
        );
      }
      final input = source['input'];
      final counts = source['counts'];
      final licenses = source['licenses'].asArray(minItems: 1, maxItems: 8);
      final attributions = source['attributions'].asArray(
        minItems: 1,
        maxItems: 16,
      );
      final parsedSource = DictionarySource(
        sourceId: sourceId,
        version: source['version'].asString(minLength: 1, maxLength: 128),
        displayName: source['display_name'].asString(
          minLength: 1,
          maxLength: 256,
        ),
        direction: source['direction'].asString(minLength: 1, maxLength: 32),
        inputUrl: Uri.parse(input['url'].uri()),
        inputSha256: input['sha256'].sha256(),
        licenses: [
          for (final license in licenses)
            DictionaryLicense(
              name: license['name'].asString(minLength: 1, maxLength: 256),
              url: Uri.parse(license['url'].uri()),
            ),
        ],
        attributions: [
          for (final attribution in attributions)
            DictionaryAttribution(
              name: attribution['name'].asString(minLength: 1, maxLength: 256),
              url: Uri.parse(attribution['url'].uri()),
            ),
        ],
        counts: DictionarySourceCounts(
          originalHeadwords: counts['original_headwords'].asInt(min: 0),
          filteredHeadwords: counts['filtered_headwords'].asInt(min: 0),
          finalHeadwords: counts['final_headwords'].asInt(min: 0),
        ),
        extractionNote: source['extraction_note'].asString(
          minLength: 1,
          maxLength: 4096,
        ),
      );
      _validateFormalSource(parsedSource, source.path);
      sources.add(parsedSource);
    }
    if (sourceIds.length != requiredSourceIds.length ||
        !sourceIds.containsAll(requiredSourceIds)) {
      throw const ContractViolation(
        'manifest.sources',
        'formal source set mismatch',
      );
    }
    final modifications = [
      for (final item in r['modifications'].asArray(minItems: 1, maxItems: 64))
        item.asString(minLength: 1, maxLength: 4096),
    ];
    final licenseFiles = [
      for (final item in r['license_files'].asArray(minItems: 2, maxItems: 16))
        item.asString(minLength: 1, maxLength: 240),
    ];
    if (licenseFiles.toSet().length != licenseFiles.length ||
        licenseFiles.any(
          (path) => !RegExp(
            r'^licenses/[A-Za-z0-9][A-Za-z0-9._-]*\.txt$',
          ).hasMatch(path),
        )) {
      throw const ContractViolation(
        'manifest.license_files',
        'invalid license path set',
      );
    }
    return DictionaryManifest(
      formatVersion: formatVersion,
      dictionaryId: dictionaryId,
      revision: r['revision'].positiveInt(),
      schemaVersion: schemaVersion,
      displayName: r['display_name'].asString(minLength: 1, maxLength: 256),
      generatedAt: r['generated_at'].dateTime(),
      builderName: builder['name'].asString(minLength: 1, maxLength: 256),
      builderVersion: builder['version'].asString(minLength: 1, maxLength: 128),
      normalizationVersion: normalizationVersion,
      databaseSize: database['size'].asInt(min: 1, max: 536870912),
      databaseSha256: database['sha256'].sha256(),
      sources: sources,
      modifications: modifications,
      licenseFiles: licenseFiles,
    );
  }

  DictionaryResource toResource({
    required String path,
    required int packageSize,
    required String packageSha256,
    required String manifestJson,
  }) => DictionaryResource(
    dictionaryId: dictionaryId,
    revision: revision,
    path: path,
    sizeBytes: packageSize,
    sha256: packageSha256,
    databaseSizeBytes: databaseSize,
    databaseSha256: databaseSha256,
    formatVersion: formatVersion,
    schemaVersion: schemaVersion,
    displayName: displayName,
    generatedAt: generatedAt,
    builderName: builderName,
    builderVersion: builderVersion,
    normalizationVersion: normalizationVersion,
    sources: sources,
    modifications: modifications,
    manifestJson: manifestJson,
  );

  static DictionaryManifest parseString(String json) => parse(jsonDecode(json));
}

void _validateFormalSource(DictionarySource source, String path) {
  final licenses = source.licenses.map((license) => license.name).toSet();
  final attributions = source.attributions
      .map((attribution) => attribution.name)
      .toSet();
  switch (source.sourceId) {
    case 'oewn-2025':
      if (source.version != '2025' ||
          source.direction != 'en-en' ||
          source.inputUrl.toString() !=
              'https://en-word.net/static/english-wordnet-2025.xml.gz' ||
          source.inputSha256 !=
              '9ca6d1dcb75f822fdd66617f7d9da48142ace38dd544d6ad5e2feca1674ad3fe' ||
          !licenses.containsAll({
            'Creative Commons Attribution 4.0 International',
            'Princeton WordNet License',
          }) ||
          !attributions.containsAll({
            'Open English WordNet',
            'Princeton WordNet',
          })) {
        throw ContractViolation(
          path,
          'oewn-2025 identity or attribution mismatch',
        );
      }
    case 'freedict-eng-zho-2025.11.23':
      if (source.version != '2025.11.23' ||
          source.direction != 'en-zh' ||
          source.inputUrl.toString() !=
              'https://download.freedict.org/dictionaries/eng-zho/2025.11.23/'
                  'freedict-eng-zho-2025.11.23.src.tar.xz' ||
          source.inputSha256 !=
              '78f6909786861809886201827e5e3d55dbf8e12f753d7a7183e785dbc574de8b' ||
          !licenses.contains('Creative Commons Attribution-ShareAlike 3.0') ||
          !attributions.containsAll({
            'FreeDict',
            'WikDict',
            'DBnary',
            'Wiktionary',
          })) {
        throw ContractViolation(
          path,
          'freedict-eng-zho-2025.11.23 identity or attribution mismatch',
        );
      }
  }
}
