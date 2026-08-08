import '../contract_violation.dart';

/// Readpack v1 `attribution.json` — provenance chain (design §6.2, NFR-LIC-001).
class ReadpackAttribution {
  const ReadpackAttribution({
    required this.formatVersion,
    required this.articleId,
    required this.revision,
    required this.resources,
  });

  final String formatVersion;
  final String articleId;
  final int revision;
  final List<AttributionResource> resources;

  static ReadpackAttribution parse(Object? json) {
    final r = JsonReader(json, 'attribution');
    r['format'].mustEqual('readpack-attribution', 'format');
    final formatVersion = r['format_version'].v1Version();
    final article = r['article'];

    final resourceReaders = r['resources'].asArray(minItems: 7, maxItems: 128);
    final resources = <AttributionResource>[];
    final ids = <String>{};
    for (var i = 0; i < resourceReaders.length; i++) {
      final res = resourceReaders[i];
      final resource = AttributionResource.parse(res, 'attribution.resources[$i]');
      if (!ids.add(resource.resourceId)) {
        throw ContractViolation(
            'attribution.resources[$i].resource_id', 'duplicate id');
      }
      resources.add(resource);
    }

    // The v1 publication profile requires one of each role.
    const requiredRoles = {
      ('article_source', 'content'),
      ('translation_service', 'translation'),
      ('tts_model', 'custom_voice'),
      ('tts_model', 'base_voice_clone'),
      ('voice_profile', 'narration'),
      ('software_dependency', 'pipeline'),
      ('software_dependency', 'audio_encoder'),
    };
    for (final required in requiredRoles) {
      final found = resources.any(
          (res) => res.kind == required.$1 && res.role == required.$2);
      if (!found) {
        throw ContractViolation('attribution.resources',
            'missing ${required.$1}/${required.$2} resource');
      }
    }

    return ReadpackAttribution(
      formatVersion: formatVersion,
      articleId: article['id'].uuid(),
      revision: article['revision'].positiveInt(),
      resources: resources,
    );
  }
}

/// `{status: known, value}` or `{status: unknown | not_applicable}`.
class ProvenanceValue {
  const ProvenanceValue.known(this.value)
      : status = 'known';

  const ProvenanceValue.unavailable(this.status) : value = null;

  final String status; // known | unknown | not_applicable
  final String? value;

  static ProvenanceValue parse(JsonReader r) {
    final status = r['status'].asString();
    switch (status) {
      case 'known':
        return ProvenanceValue.known(
            r['value'].asString(minLength: 1, maxLength: 4096));
      case 'unknown':
      case 'not_applicable':
        if (r.optional('value') != null) {
          throw ContractViolation(
              r.path, 'status "$status" must not carry a value');
        }
        return ProvenanceValue.unavailable(status);
      default:
        throw ContractViolation('${r.path}.status', 'unknown status "$status"');
    }
  }

  /// Display text; unknown/n-a fields are shown explicitly (screen 15).
  String get display => status == 'known' ? value! : status;
}

class AttributionLicense {
  const AttributionLicense.known(this.name, this.url) : status = 'known';

  const AttributionLicense.unavailable(this.status)
      : name = null,
        url = null;

  final String status;
  final String? name;
  final String? url;

  static AttributionLicense parse(JsonReader r) {
    final status = r['status'].asString();
    switch (status) {
      case 'known':
        return AttributionLicense.known(
          r['name'].asString(minLength: 1, maxLength: 512),
          r.optional('url')?.uriOrNull(),
        );
      case 'unknown':
      case 'not_applicable':
        if (r.optional('name') != null || r.optional('url') != null) {
          throw ContractViolation(
              r.path, 'status "$status" must not carry name/url');
        }
        return AttributionLicense.unavailable(status);
      default:
        throw ContractViolation('${r.path}.status', 'unknown status "$status"');
    }
  }

  String get display => status == 'known' ? name! : status;
}

class AttributionResource {
  const AttributionResource({
    required this.resourceId,
    required this.kind,
    required this.role,
    required this.name,
    required this.source,
    required this.version,
    required this.license,
    required this.modifications,
    required this.hashes,
    this.notes,
  });

  final String resourceId;
  final String kind;
  final String role;
  final String name;
  final ProvenanceValue source;
  final ProvenanceValue version;
  final AttributionLicense license;
  final ProvenanceValue modifications;
  final List<String> hashes;
  final String? notes;

  static const _kinds = {
    'article_source',
    'translation_service',
    'tts_model',
    'voice_profile',
    'software_dependency',
  };

  static AttributionResource parse(JsonReader r, String path) {
    final kind = r['kind'].asString();
    if (!_kinds.contains(kind)) {
      throw ContractViolation('${r.path}.kind', 'unknown kind "$kind"');
    }
    final hashReaders =
        r['hashes'].asArray(maxItems: 16);
    final hashes = <String>[];
    final seen = <String>{};
    for (var i = 0; i < hashReaders.length; i++) {
      final h = hashReaders[i];
      h['algorithm'].mustEqual('sha256', 'hash algorithm');
      final value = h['value'].sha256();
      if (!seen.add(value)) {
        throw ContractViolation('${r.path}.hashes[$i]', 'duplicate hash');
      }
      hashes.add(value);
    }
    return AttributionResource(
      resourceId: r['resource_id'].opaqueId(),
      kind: kind,
      role: r['role'].asString(minLength: 1, maxLength: 128),
      name: r['name'].asString(minLength: 1, maxLength: 512),
      source: ProvenanceValue.parse(r['source']),
      version: ProvenanceValue.parse(r['version']),
      license: AttributionLicense.parse(r['license']),
      modifications: ProvenanceValue.parse(r['modifications']),
      hashes: hashes,
      notes: r.optional('notes')?.asStringOrNull(minLength: 1, maxLength: 4096),
    );
  }
}
