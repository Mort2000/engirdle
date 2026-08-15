import '../contract_violation.dart';

/// Readpack v1 `manifest.json` — the envelope metadata (design §6.2).
class ReadpackManifest {
  const ReadpackManifest({
    required this.formatVersion,
    required this.requiredCapabilities,
    required this.packageId,
    required this.createdAt,
    required this.articleId,
    required this.revision,
    required this.artifactRevision,
    required this.files,
    required this.audio,
    required this.pipeline,
  });

  final String formatVersion;

  /// `required_capabilities`, parsed with the schema array rules (≤ 8 unique
  /// lowercase tokens). Which capabilities a given minor may declare is a
  /// cross-file semantic rule, checked by the validator — not this parser.
  final List<String> requiredCapabilities;

  final String packageId;
  final String createdAt;
  final String articleId;
  final int revision;
  final int artifactRevision;
  final List<ManifestFileEntry> files;
  final ManifestAudio audio;
  final ManifestPipeline pipeline;

  /// Parses and strictly validates against the v1 manifest schema plus the
  /// compatibility rules (COMPATIBILITY.md): unknown optional fields are
  /// ignored; `required_capabilities` follows the schema array rules and
  /// which tokens a minor may declare is left to the cross-file validator.
  static ReadpackManifest parse(Object? json) {
    final r = JsonReader(json, 'manifest');
    r['format'].mustEqual('readpack', 'format');
    final formatVersion = r['format_version'].v1Version();

    // v1.1 opens the capability array to ≤ 8 unique tokens
    // (`^[a-z][a-z0-9-]*$`, 1-64 chars). Which tokens a given minor may
    // declare is a semantic rule: v1.0 must stay empty, v1.1 must declare
    // `markdown-blocks`, unknown tokens always reject — all in the
    // cross-file validator, where manifest and article can be compared.
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
        throw ContractViolation('manifest.required_capabilities[$i]',
            'duplicate capability "$capability"');
      }
      capabilities.add(capability);
    }

    final article = r['article'];
    final files = r['files'].asArray(minItems: 3, maxItems: 3);
    final parsedFiles = <ManifestFileEntry>[];
    final seenPaths = <String>{};
    // The v1 layout only ever declares these three files.
    const allowed = {
      'article.json': 'application/json',
      'attribution.json': 'application/json',
      'audio/article.m4a': 'audio/mp4',
    };
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      final entry = ManifestFileEntry(
        path: f['path'].asString(),
        size: f['size'].asInt(min: 1, max: 1073741824),
        sha256: f['sha256'].sha256(),
        mediaType: f['media_type'].asString(),
      );
      final expectedMedia = allowed[entry.path];
      if (expectedMedia == null) {
        throw ContractViolation(
            'manifest.files[$i].path', 'unexpected file "${entry.path}"');
      }
      if (entry.mediaType != expectedMedia) {
        throw ContractViolation('manifest.files[$i].media_type',
            'expected "$expectedMedia" for ${entry.path}');
      }
      if (!seenPaths.add(entry.path)) {
        throw ContractViolation(
            'manifest.files[$i].path', 'duplicate file "${entry.path}"');
      }
      parsedFiles.add(entry);
    }
    for (final requiredPath in allowed.keys) {
      if (!seenPaths.contains(requiredPath)) {
        throw ContractViolation('manifest.files', 'missing "$requiredPath"');
      }
    }

    final audio = r['audio'];
    final parsedAudio = ManifestAudio(
      path: audio['path'].asString(),
      codec: audio['codec'].asString(),
      sampleRateHz: audio['sample_rate_hz'].asInt(),
      channels: audio['channels'].asInt(),
      durationMs: audio['duration_ms'].asInt(min: 1, max: 86400000),
    );
    if (parsedAudio.path != 'audio/article.m4a') {
      throw const ContractViolation(
          'manifest.audio.path', 'unexpected audio path');
    }
    if (parsedAudio.codec != 'aac-lc') {
      throw const ContractViolation('manifest.audio.codec', 'expected aac-lc');
    }
    if (parsedAudio.sampleRateHz != 24000) {
      throw const ContractViolation(
          'manifest.audio.sample_rate_hz', 'expected 24000');
    }
    if (parsedAudio.channels != 1) {
      throw const ContractViolation('manifest.audio.channels', 'expected mono');
    }

    final pipeline = r['pipeline'];
    final translation = pipeline['translation'];
    final tts = pipeline['tts'];
    final parsedPipeline = ManifestPipeline(
      version: pipeline['version'].semanticVersion(),
      segmenter: pipeline['segmenter'].revisionedIdentifier(),
      translationProvider: translation['provider'].asString(minLength: 1),
      translationModel: translation['model'].asString(minLength: 1),
      translationThinking: translation['thinking'].asString(minLength: 1),
      translationReasoningEffort:
          translation['reasoning_effort'].asString(minLength: 1),
      translationPrompt: translation['prompt'].revisionedIdentifier(),
      ttsCustomVoiceModel: tts['custom_voice_model'].revisionedIdentifier(),
      ttsBaseModel: tts['base_model'].revisionedIdentifier(),
      voiceProfile: tts['voice_profile'].revisionedIdentifier(),
      anchorSha256: tts['anchor_sha256'].sha256(),
    );

    return ReadpackManifest(
      formatVersion: formatVersion,
      requiredCapabilities: capabilities,
      packageId: r['package_id'].uuid(),
      createdAt: r['created_at'].dateTime(),
      articleId: article['id'].uuid(),
      revision: article['revision'].positiveInt(),
      artifactRevision: article['artifact_revision'].positiveInt(),
      files: parsedFiles,
      audio: parsedAudio,
      pipeline: parsedPipeline,
    );
  }

  ManifestFileEntry fileFor(String path) =>
      files.firstWhere((f) => f.path == path);
}

class ManifestFileEntry {
  const ManifestFileEntry({
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

class ManifestAudio {
  const ManifestAudio({
    required this.path,
    required this.codec,
    required this.sampleRateHz,
    required this.channels,
    required this.durationMs,
  });

  final String path;
  final String codec;
  final int sampleRateHz;
  final int channels;
  final int durationMs;
}

class ManifestPipeline {
  const ManifestPipeline({
    required this.version,
    required this.segmenter,
    required this.translationProvider,
    required this.translationModel,
    required this.translationThinking,
    required this.translationReasoningEffort,
    required this.translationPrompt,
    required this.ttsCustomVoiceModel,
    required this.ttsBaseModel,
    required this.voiceProfile,
    required this.anchorSha256,
  });

  final String version;
  final String segmenter;
  final String translationProvider;
  final String translationModel;
  final String translationThinking;
  final String translationReasoningEffort;
  final String translationPrompt;
  final String ttsCustomVoiceModel;
  final String ttsBaseModel;
  final String voiceProfile;
  final String anchorSha256;
}
