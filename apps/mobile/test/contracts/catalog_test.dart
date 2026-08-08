import 'dart:convert';

import 'package:engirdle_mobile/contracts/catalog_v1/catalog.dart';
import 'package:engirdle_mobile/contracts/contract_violation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_helpers.dart';

/// Catalog fixtures from contracts/catalog/v1/fixtures (fixtures/README.md).
/// The origin is the documented catalog location for the invalid fixtures.
void main() {
  final origin = Uri.parse('http://192.0.2.10:8766/catalog.json');

  Catalog parseFixture(String relative) {
    final json = jsonDecode(catalogFixture(relative).readAsStringSync());
    return Catalog.parse(json, origin: origin);
  }

  group('catalog v1 fixtures', () {
    test('valid/minimal.json is accepted', () {
      final catalog = parseFixture('valid/minimal.json');
      expect(catalog.catalogVersion, 1);
      expect(catalog.packages, hasLength(1));
      final package = catalog.packages.single;
      expect(package.formatVersion, startsWith('1.'));
      // Relative package URLs resolve against the catalog origin.
      expect(package.url.scheme, 'http');
      expect(package.url.host, '192.0.2.10');
      expect(package.url.port, 8766);
      expect(package.url.path,
          '/packages/22222222-2222-4222-8222-222222222222.readpack');
    });

    final violations = <String, Pattern>{
      'invalid/duplicate-article.json': 'duplicate article',
      'invalid/duplicate-url.json': 'duplicate url',
      'invalid/unsafe-url.json': 'unsafe url',
      'invalid/cross-origin-url.json': 'cross-origin url',
      'invalid/unsupported-major.json': 'unsupported major version',
    };
    for (final entry in violations.entries) {
      test('${entry.key} is rejected', () {
        expect(
          () => parseFixture(entry.key),
          throwsA(isA<ContractViolation>().having(
              (v) => v.problem, 'problem', contains(entry.value as String))),
        );
      });
    }
  });
}
