import 'dart:convert';

import 'package:engirdle_mobile/contracts/contract_violation.dart';
import 'package:engirdle_mobile/contracts/dictionary_v2/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_helpers.dart';

void main() {
  DictionaryManifest parseFixture(String relative) => DictionaryManifest.parse(
    jsonDecode(dictionaryV2Fixture(relative).readAsStringSync()),
  );

  group('dictionary v2 manifest fixtures', () {
    test('valid/minimal.json is accepted', () {
      final manifest = parseFixture('valid/minimal.json');

      expect(manifest.formatVersion, '2.0');
      expect(manifest.schemaVersion, 2);
      expect(manifest.sources.map((source) => source.sourceId), [
        'oewn-2025',
        'omw-cmn:2.0',
      ]);
    });

    for (final fixture in [
      'invalid/unsupported-major.json',
      'invalid/wrong-source-set.json',
    ]) {
      test('$fixture is rejected', () {
        expect(() => parseFixture(fixture), throwsA(isA<ContractViolation>()));
      });
    }
  });
}
