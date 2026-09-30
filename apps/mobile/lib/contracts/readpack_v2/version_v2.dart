import '../contract_violation.dart';

/// The `2.y` format-version value object shared by every v2 document parser
/// (manifest, article, attribution, translation, narration).
///
/// Compatibility rule (contracts/README.md, readpack/v2/COMPATIBILITY.md):
/// an implementation accepts every minor of its own major and rejects other
/// majors; newer minors may only add ignorable fields, which the readers skip
/// by construction. Semantic extensions this build cannot honor must surface
/// through `required_capabilities` (rejected by the validator), not through
/// a pinned minor.
class ReadpackV2Version {
  const ReadpackV2Version._(this.minor, this.wire);

  final int minor;
  final String wire;

  static ReadpackV2Version parse(JsonReader r) {
    final value = r.asString();
    final match = RegExp(r'^(\d+)\.(\d+)$').firstMatch(value);
    if (match == null) {
      throw ContractViolation(r.path, 'malformed format_version "$value"');
    }
    if (match.group(1) != '2') {
      throw ContractViolation(r.path, 'unsupported major version "$value"');
    }
    return ReadpackV2Version._(int.parse(match.group(2)!), value);
  }
}
