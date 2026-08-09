/// Raised when a catalog/readpack document violates the v1 contract.
///
/// Violations are contract errors, never user text: presentation maps them to
/// the package-format failure category; the detail goes to logs.
class ContractViolation implements Exception {
  const ContractViolation(this.path, this.problem);

  /// JSON path of the offending value (e.g. `manifest.files[1].sha256`).
  final String path;
  final String problem;

  @override
  String toString() => 'ContractViolation($path: $problem)';
}

/// Type-checked access into untrusted decoded JSON.
///
/// Every accessor throws [ContractViolation] with a precise path instead of
/// leaking type errors. Unknown fields are tolerated (v1 minor-compatible),
/// unless a validator explicitly forbids them.
class JsonReader {
  const JsonReader(this.value, this.path);

  final Object? value;
  final String path;

  ContractViolation _error(String problem) => ContractViolation(path, problem);

  Map<String, Object?> asObject() {
    if (value is Map<String, Object?>) return value as Map<String, Object?>;
    throw _error('expected object, got ${value.runtimeType}');
  }

  List<JsonReader> asArray({int? minItems, int? maxItems}) {
    if (value is! List) throw _error('expected array, got ${value.runtimeType}');
    final list = value! as List<Object?>;
    if (minItems != null && list.length < minItems) {
      throw _error('expected at least $minItems items');
    }
    if (maxItems != null && list.length > maxItems) {
      throw _error('expected at most $maxItems items');
    }
    return [
      for (var i = 0; i < list.length; i++) JsonReader(list[i], '$path[$i]'),
    ];
  }

  String asString({int? minLength, int? maxLength, RegExp? pattern}) {
    if (value is! String) throw _error('expected string');
    final s = value! as String;
    if (minLength != null && s.length < minLength) {
      throw _error('string shorter than $minLength');
    }
    if (maxLength != null && s.length > maxLength) {
      throw _error('string longer than $maxLength');
    }
    if (pattern != null && !pattern.hasMatch(s)) {
      throw _error('string does not match $pattern');
    }
    return s;
  }

  String? asStringOrNull({int? minLength, int? maxLength}) {
    if (value == null) return null;
    return asString(minLength: minLength, maxLength: maxLength);
  }

  int asInt({int? min, int? max}) {
    if (value is! int) throw _error('expected integer');
    final i = value! as int;
    if (min != null && i < min) throw _error('integer below $min');
    if (max != null && i > max) throw _error('integer above $max');
    return i;
  }

  /// Required child of an object.
  JsonReader operator [](String key) {
    final map = asObject();
    if (!map.containsKey(key)) throw _error('missing required key "$key"');
    return JsonReader(map[key], '$path.$key');
  }

  /// Optional child of an object; [fallback] when absent.
  JsonReader? optional(String key) {
    final map = asObject();
    if (!map.containsKey(key)) return null;
    return JsonReader(map[key], '$path.$key');
  }

  JsonReader at(int index) {
    final list = asArray();
    return JsonReader(list[index], '$path[$index]');
  }

  void mustEqual(Object? expected, String what) {
    if (value != expected) {
      throw _error('expected $what "$expected", got "$value"');
    }
  }
}

final _v1VersionPattern = RegExp(r'^1\.[0-9]+$');
final _v2VersionPattern = RegExp(r'^2\.[0-9]+$');
final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final _opaqueIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$');
final _semanticVersionPattern =
    RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$');
final _revisionedIdentifierPattern = RegExp(r'^.+@[^@]+$');

// Capture groups feed the calendar cross-check in dateTime(); the RFC 3339
// offset must carry a colon (`+08:00`, never `+0800`).
final _dateTimePattern = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-](\d{2}):(\d{2}))$');

/// Shared scalar validators mirroring the v1 `$defs`.
extension ContractScalars on JsonReader {
  String v1Version() {
    final s = asString();
    if (!_v1VersionPattern.hasMatch(s)) {
      throw ContractViolation(path, 'unsupported major version "$s"');
    }
    return s;
  }

  String v2Version() {
    final s = asString();
    if (!_v2VersionPattern.hasMatch(s)) {
      throw ContractViolation(path, 'unsupported major version "$s"');
    }
    return s;
  }

  String uuid() => asString(pattern: _uuidPattern);

  String sha256() {
    final s = asString();
    if (!_sha256Pattern.hasMatch(s)) {
      throw ContractViolation(path, 'invalid sha256');
    }
    return s;
  }

  String opaqueId({int maxLength = 128}) {
    final s = asString(minLength: 1, maxLength: maxLength);
    // The schema pattern is the whole rule: `a..b` is legal. These ids are
    // opaque to consumers and never join a file path, so a stricter local
    // rule would only break forward compatibility with later 1.x minors.
    if (!_opaqueIdPattern.hasMatch(s)) {
      throw ContractViolation(path, 'invalid opaque id "$s"');
    }
    return s;
  }

  /// JSON Schema `format: date-time` (RFC 3339). Dart's parser normalizes
  /// overflow (month 13 rolls into the next year) instead of rejecting, so
  /// the calendar components are cross-checked after the shape match.
  String dateTime() {
    final s = asString();
    final m = _dateTimePattern.firstMatch(s);
    if (m == null) {
      throw ContractViolation(path, 'invalid date-time "$s"');
    }
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    final hour = int.parse(m.group(4)!);
    final minute = int.parse(m.group(5)!);
    final second = int.parse(m.group(6)!);
    final offsetHour = m.group(9) == null ? 0 : int.parse(m.group(9)!);
    final offsetMinute = m.group(10) == null ? 0 : int.parse(m.group(10)!);
    final dayRoundTrip = DateTime.utc(year, month, day);
    final valid = dayRoundTrip.year == year &&
        dayRoundTrip.month == month &&
        dayRoundTrip.day == day &&
        hour < 24 &&
        minute < 60 &&
        second < 60 &&
        offsetHour < 24 &&
        offsetMinute < 60 &&
        DateTime.tryParse(s) != null;
    if (!valid) {
      throw ContractViolation(path, 'invalid date-time "$s"');
    }
    return s;
  }

  /// Manifest `semanticVersion` ($defs): semver shape, no length cap in the
  /// schema (the floor of 5 is the shortest possible `x.y.z`).
  String semanticVersion() =>
      asString(minLength: 5, pattern: _semanticVersionPattern);

  /// Manifest `revisionedIdentifier` ($defs): `name@revision`.
  String revisionedIdentifier() => asString(
      minLength: 3, maxLength: 512, pattern: _revisionedIdentifierPattern);

  /// JSON Schema `format: uri`: a parseable absolute URI, i.e. the scheme
  /// must be present.
  String uri({int maxLength = 2048}) {
    final s = asString(maxLength: maxLength);
    final parsed = Uri.tryParse(s);
    if (parsed == null || parsed.scheme.isEmpty) {
      throw ContractViolation(path, 'invalid uri "$s"');
    }
    return s;
  }

  String? uriOrNull({int maxLength = 2048}) {
    if (value == null) return null;
    return uri(maxLength: maxLength);
  }

  int positiveInt() => asInt(min: 1, max: 2147483647);

  int order() => asInt(min: 0, max: 2147483647);

  int samplePosition() => asInt(min: 0, max: 9007199254740991);

  int millisecondPosition() => asInt(min: 0, max: 86400000);
}
