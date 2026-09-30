import 'dart:convert';

import '../contract_violation.dart';
import '../readpack_v1/attribution.dart' show AttributionResource;
import 'version_v2.dart';

/// Readpack v2 `manifest.json` — the layered envelope (contracts/readpack/v2).
class ReadpackV2Manifest {
  const ReadpackV2Manifest({
    required this.formatVersion,
    required this.requiredCapabilities,
    required this.packageId,
    required this.createdAt,
    required this.articleId,
    required this.revision,
    required this.artifactRevision,
    required this.files,
    required this.structureSha256,
    this.parserVersion,
    required this.segmenterVersion,
    required this.translations,
    this.narration,
  });

  final String formatVersion;
  final List<String> requiredCapabilities;
  final String packageId;
  final String createdAt;
  final String articleId;
  final int revision;
  final int artifactRevision;
  final List<V2FileEntry> files;
  final String structureSha256;
  final String? parserVersion;
  final String segmenterVersion;
  final List<V2TranslationDescriptor> translations;
  final V2NarrationDescriptor? narration;

  static ReadpackV2Manifest parse(Object? json) {
    final r = JsonReader(json, 'manifest');
    r['format'].mustEqual('readpack', 'format');
    final formatVersion = ReadpackV2Version.parse(r['format_version']).wire;

    final capabilities = <String>[];
    final capabilityReaders =
        r.optional('required_capabilities')?.asArray(maxItems: 8) ??
        const <JsonReader>[];
    for (var i = 0; i < capabilityReaders.length; i++) {
      final capability = capabilityReaders[i].asString(
        minLength: 1,
        maxLength: 64,
        pattern: RegExp(r'^[a-z][a-z0-9-]*$'),
      );
      if (capabilities.contains(capability)) {
        throw ContractViolation(
          'manifest.required_capabilities[$i]',
          'duplicate capability "$capability"',
        );
      }
      capabilities.add(capability);
    }

    final article = r['article'];
    final files = r['files'].asArray(minItems: 2, maxItems: 5);
    final parsedFiles = <V2FileEntry>[];
    final seenPaths = <String>{};
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      final path = f['path'].asString();
      final mediaType = f['media_type'].asString();
      _requireSchemaFileShape(i, path, mediaType);
      final entry = V2FileEntry(
        path: path,
        size: f['size'].asInt(min: 1, max: 1073741824),
        sha256: f['sha256'].sha256(),
        mediaType: mediaType,
      );
      if (!seenPaths.add(entry.path)) {
        throw ContractViolation(
          'manifest.files[$i].path',
          'duplicate file "${entry.path}"',
        );
      }
      parsedFiles.add(entry);
    }
    for (final required in ['article.json', 'attribution.json']) {
      if (!seenPaths.contains(required)) {
        throw ContractViolation('manifest.files', 'missing "$required"');
      }
    }

    final content = r['content'];
    _fixedString(content['path'], 'article.json');
    final derivatives = r['derivatives'];
    final translationReaders = derivatives['translations'].asArray(maxItems: 8);
    final translations = [
      for (final t in translationReaders)
        V2TranslationDescriptor(
          locale: t['locale'].asString(
            pattern: RegExp(r'^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$'),
          ),
          path: t['path'].asString(
            pattern: RegExp(
              r'^derivatives/translation\.[A-Za-z0-9]{2,8}(-[A-Za-z0-9]{2,8})*\.json$',
            ),
          ),
        ),
    ];
    final narrationReader = derivatives.optional('narration');
    final hasNarration = narrationReader?.value != null;
    final narration = hasNarration
        ? V2NarrationDescriptor(
            path: _fixedString(
              narrationReader!['path'],
              'derivatives/narration.json',
            ),
            audioPath: _fixedString(
              narrationReader['audio_path'],
              'audio/article.m4a',
            ),
          )
        : null;

    return ReadpackV2Manifest(
      formatVersion: formatVersion,
      requiredCapabilities: capabilities,
      packageId: r['package_id'].uuid(),
      createdAt: r['created_at'].dateTime(),
      articleId: article['id'].uuid(),
      revision: article['revision'].positiveInt(),
      artifactRevision: article['artifact_revision'].positiveInt(),
      files: parsedFiles,
      structureSha256: content['structure_sha256'].sha256(),
      parserVersion: content.optional('parser')?.revisionedIdentifier(),
      segmenterVersion: content['segmenter'].revisionedIdentifier(),
      translations: translations,
      narration: narration,
    );
  }
}

/// Typed allow-list mirroring the manifest schema's `files[].oneOf`: every
/// declared payload must be one of the five fixed-layout paths carrying its
/// exact media type (contracts/readpack/v2 README 逻辑布局). Anything else —
/// e.g. a `notes.txt` the ZIP really contains — is rejected here, before the
/// container's declared-set-equals-actual-set check could accept it.
void _requireSchemaFileShape(int index, String path, String mediaType) {
  final String expectedMedia;
  if (path == 'article.json' ||
      path == 'attribution.json' ||
      path == 'derivatives/narration.json' ||
      _translationPathPattern.hasMatch(path)) {
    expectedMedia = 'application/json';
  } else if (path == 'audio/article.m4a') {
    expectedMedia = 'audio/mp4';
  } else {
    throw ContractViolation(
      'manifest.files[$index].path',
      '"$path" is not part of the v2 fixed layout',
    );
  }
  if (mediaType != expectedMedia) {
    throw ContractViolation(
      'manifest.files[$index].media_type',
      'expected "$expectedMedia" for "$path", got "$mediaType"',
    );
  }
}

final RegExp _translationPathPattern = RegExp(
  r'^derivatives/translation\.[A-Za-z0-9]{2,8}(-[A-Za-z0-9]{2,8})*\.json$',
);

String _fixedString(JsonReader r, String expected) {
  final value = r.asString();
  if (value != expected) {
    throw ContractViolation(r.path, 'expected "$expected", got "$value"');
  }
  return value;
}

class V2FileEntry {
  const V2FileEntry({
    required this.path,
    required this.size,
    required this.sha256,
    required this.mediaType,
  });

  final String path;
  final int size;
  final String sha256;
  final String mediaType;
}

class V2TranslationDescriptor {
  const V2TranslationDescriptor({required this.locale, required this.path});

  final String locale;
  final String path;
}

class V2NarrationDescriptor {
  const V2NarrationDescriptor({required this.path, required this.audioPath});

  final String path;
  final String audioPath;
}

/// Readpack v2 `attribution.json`. The resource model is shared with v1
/// (same kind/role/provenance shapes); the envelope differs: 2.x version,
/// ≥2 resources, the unconditional roles are article_source/content and
/// software_dependency/pipeline, and derivative presence pulls in the
/// translation/narration roles (v2 README data rules).
class ReadpackV2Attribution {
  const ReadpackV2Attribution({
    required this.formatVersion,
    required this.articleId,
    required this.revision,
    required this.resources,
  });

  final String formatVersion;
  final String articleId;
  final int revision;
  final List<AttributionResource> resources;

  static ReadpackV2Attribution parse(Object? json) {
    final r = JsonReader(json, 'attribution');
    r['format'].mustEqual('readpack-attribution', 'format');
    final formatVersion = ReadpackV2Version.parse(r['format_version']).wire;
    final article = r['article'];

    final resourceReaders = r['resources'].asArray(minItems: 2, maxItems: 128);
    final resources = <AttributionResource>[];
    final ids = <String>{};
    for (var i = 0; i < resourceReaders.length; i++) {
      final resource = AttributionResource.parse(
        resourceReaders[i],
        'attribution.resources[$i]',
      );
      if (!ids.add(resource.resourceId)) {
        throw ContractViolation(
          'attribution.resources[$i].resource_id',
          'duplicate id',
        );
      }
      resources.add(resource);
    }

    bool hasRole(String kind, String role) =>
        resources.any((res) => res.kind == kind && res.role == role);
    if (!hasRole('article_source', 'content') ||
        !hasRole('software_dependency', 'pipeline')) {
      throw const ContractViolation(
        'attribution.resources',
        'v2 needs an article_source/content and a software_dependency/pipeline '
            'resource',
      );
    }
    return ReadpackV2Attribution(
      formatVersion: formatVersion,
      articleId: article['id'].uuid(),
      revision: article['revision'].positiveInt(),
      resources: resources,
    );
  }

  /// Derivative-conditional attribution roles (v2 README): a translation
  /// needs its service declared; narration needs both TTS models, the voice
  /// profile and the audio encoder.
  void requireDerivativeAttribution({
    required bool translationPresent,
    required bool narrationPresent,
  }) {
    bool hasRole(String kind, String role) =>
        resources.any((res) => res.kind == kind && res.role == role);
    if (translationPresent && !hasRole('translation_service', 'translation')) {
      throw const ContractViolation(
        'attribution.resources',
        'a translation derivative requires translation_service/translation',
      );
    }
    if (narrationPresent) {
      const narrationRoles = [
        ('tts_model', 'custom_voice'),
        ('tts_model', 'base_voice_clone'),
        ('voice_profile', 'narration'),
        ('software_dependency', 'audio_encoder'),
      ];
      for (final (kind, role) in narrationRoles) {
        if (!hasRole(kind, role)) {
          throw ContractViolation(
            'attribution.resources',
            'a narration derivative requires $kind/$role',
          );
        }
      }
    }
  }
}

/// Convenience re-export so validator callers never touch raw jsonDecode.
Object? decodeJsonOrViolation(String source, String path) {
  try {
    return jsonDecode(source);
  } on FormatException {
    throw ContractViolation(path, 'invalid json');
  }
}
