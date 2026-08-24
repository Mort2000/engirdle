import 'dart:convert';

import '../contract_violation.dart';

/// The v2 translation derivative (`derivatives/translation.<locale>.json`).
class TranslationV2 {
  const TranslationV2({
    required this.articleId,
    required this.revision,
    required this.structureSha256,
    required this.targetLocale,
    required this.sentences,
    required this.tables,
    required this.pipelineJson,
  });

  final String articleId;
  final int revision;
  final String structureSha256;
  final String targetLocale;
  final List<(String sentenceId, String text)> sentences;
  final List<(String blockId, List<(String cellId, String text)> cells)> tables;

  /// The pipeline snapshot (provider/model/prompt/thinking/reasoning/
  /// created_at/client_version), kept raw for the attribution page.
  final String pipelineJson;

  static TranslationV2 parse(Object? json) {
    final r = JsonReader(json, 'translation');
    r['format'].mustEqual('readpack-translation', 'format');
    final formatVersion = r['format_version'].asString(
      pattern: RegExp(r'^2\.[0-9]+$'),
    );
    if (formatVersion != '2.0') {
      throw ContractViolation(
        'translation.format_version',
        'unsupported v2 minor "$formatVersion"',
      );
    }
    final article = r['article'];

    final sentences = <(String, String)>[];
    final sentenceIds = <String>{};
    for (final s in r['sentences'].asArray(maxItems: 100000)) {
      final id = s['sentence_id'].opaqueId();
      if (!sentenceIds.add(id)) {
        throw ContractViolation('translation.sentences', 'duplicate "$id"');
      }
      sentences.add((id, s['text'].asString(minLength: 1, maxLength: 40000)));
    }

    final tables =
        <(String blockId, List<(String cellId, String text)> cells)>[];
    for (final t in r['tables'].asArray(maxItems: 10000)) {
      final blockId = t['block_id'].opaqueId();
      final cells = [
        for (final c in t['cells'].asArray(minItems: 1, maxItems: 8192))
          (
            c['cell_id'].opaqueId(),
            c['text'].asString(minLength: 1, maxLength: 40000),
          ),
      ];
      tables.add((blockId, cells));
    }

    return TranslationV2(
      articleId: article['id'].uuid(),
      revision: article['revision'].positiveInt(),
      structureSha256: r['structure_sha256'].sha256(),
      targetLocale: r['target_locale'].asString(
        pattern: RegExp(r'^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$'),
      ),
      sentences: sentences,
      tables: tables,
      pipelineJson: jsonEncode(_requirePipeline(r['pipeline'])),
    );
  }

  static Map<String, Object?> _requirePipeline(JsonReader pipeline) {
    final required = [
      'provider',
      'model',
      'prompt',
      'thinking',
      'reasoning_effort',
      'created_at',
      'client_version',
    ];
    for (final field in required) {
      // Access each field so the reader enforces presence; the raw object is
      // re-encoded below.
      pipeline[field].asString(minLength: 1);
    }
    if (pipeline.value is! Map<String, Object?>) {
      throw const ContractViolation(
        'translation.pipeline',
        'must be an object',
      );
    }
    return Map<String, Object?>.from(pipeline.value as Map);
  }
}

/// The v2 narration derivative (`derivatives/narration.json`).
class NarrationV2 {
  const NarrationV2({
    required this.articleId,
    required this.revision,
    required this.structureSha256,
    required this.audioPath,
    required this.codec,
    required this.sampleRateHz,
    required this.channels,
    required this.durationMs,
    required this.ranges,
  });

  final String articleId;
  final int revision;
  final String structureSha256;
  final String audioPath;
  final String codec;
  final int sampleRateHz;
  final int channels;
  final int durationMs;
  final List<
    (String sentenceId, int startMs, int endMs, int startSample, int endSample)
  >
  ranges;

  static NarrationV2 parse(Object? json) {
    final r = JsonReader(json, 'narration');
    r['format'].mustEqual('readpack-narration', 'format');
    final formatVersion = r['format_version'].asString(
      pattern: RegExp(r'^2\.[0-9]+$'),
    );
    if (formatVersion != '2.0') {
      throw ContractViolation(
        'narration.format_version',
        'unsupported v2 minor "$formatVersion"',
      );
    }
    final article = r['article'];
    final audio = r['audio'];
    final audioPath = audio['path'].asString();
    if (audioPath != 'audio/article.m4a') {
      throw const ContractViolation(
        'narration.audio.path',
        'unexpected audio path',
      );
    }
    final codec = audio['codec'].asString();
    if (codec != 'aac-lc') {
      throw const ContractViolation('narration.audio.codec', 'expected aac-lc');
    }
    final sampleRate = audio['sample_rate_hz'].asInt();
    if (sampleRate != 24000) {
      throw const ContractViolation(
        'narration.audio.sample_rate_hz',
        'expected 24000',
      );
    }
    final channels = audio['channels'].asInt();
    if (channels != 1) {
      throw const ContractViolation(
        'narration.audio.channels',
        'expected mono',
      );
    }

    final ranges =
        <
          (
            String sentenceId,
            int startMs,
            int endMs,
            int startSample,
            int endSample,
          )
        >[];
    final seen = <String>{};
    for (final s in r['sentences'].asArray(minItems: 1, maxItems: 100000)) {
      final id = s['sentence_id'].opaqueId();
      if (!seen.add(id)) {
        throw ContractViolation('narration.sentences', 'duplicate "$id"');
      }
      ranges.add((
        id,
        s['audio_start_ms'].millisecondPosition(),
        s['audio_end_ms'].millisecondPosition(),
        s['audio_start_sample'].samplePosition(),
        s['audio_end_sample'].samplePosition(),
      ));
    }

    return NarrationV2(
      articleId: article['id'].uuid(),
      revision: article['revision'].positiveInt(),
      structureSha256: r['structure_sha256'].sha256(),
      audioPath: audioPath,
      codec: codec,
      sampleRateHz: sampleRate,
      channels: channels,
      durationMs: audio['duration_ms'].asInt(min: 1, max: 86400000),
      ranges: ranges,
    );
  }
}
