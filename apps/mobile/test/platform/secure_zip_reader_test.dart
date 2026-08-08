import 'dart:io';

import 'package:engirdle_mobile/platform/zip/secure_zip_reader.dart';
import 'package:engirdle_mobile/shared_kernel/failures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_zip_builder.dart';

/// Hostile-archive matrix for the secure ZIP reader (design §6.5). The
/// fixtures cover parser-level rules; these tests cover declared limits,
/// entry types and byte-accurate streaming extraction.
void main() {
  const reader = SecureZipReader();
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('zip_test_');
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<File> writeZip(String name, List<int> bytes) async {
    final file = File(p.join(temp.path, name));
    await file.writeAsBytes(bytes);
    return file;
  }

  Matcher packageFailure(Pattern message) => throwsA(
      isA<AppFailure>().having((f) => f.message, 'message', contains(message)));

  test('round-trips stored and deflated entries byte-accurately', () async {
    final builder = TestZipBuilder()
      ..addStored('manifest.json', '{"ok":true}'.codeUnits)
      ..addDeflated(
          'audio/article.m4a', List<int>.generate(5000, (i) => i % 251));
    final zip = await writeZip('ok.zip', builder.build());

    final entries = await reader.preflight(zip);
    expect(entries.map((e) => e.path),
        containsAll(<String>['manifest.json', 'audio/article.m4a']));

    final m4a = entries.firstWhere((e) => e.path == 'audio/article.m4a');
    expect(m4a.isDeflated, isTrue);
    final target = File(p.join(temp.path, 'out', 'article.m4a'));
    final written = await reader.extractEntry(zip, m4a, target);
    expect(written, 5000);
    expect(await target.readAsBytes(),
        equals(List<int>.generate(5000, (i) => i % 251)));
  });

  test('rejects path traversal with forward slashes', () async {
    final zip =
        await writeZip('t.zip', (TestZipBuilder()..addStored('../escape.txt', [1])).build());
    await expectLater(reader.preflight(zip), packageFailure('unsafe path'));
  });

  test('rejects path traversal with backslashes', () async {
    final zip = await writeZip(
        't.zip', (TestZipBuilder()..addStored('..\\escape.txt', [1])).build());
    await expectLater(reader.preflight(zip), packageFailure('unsafe path'));
  });

  test('rejects absolute paths', () async {
    final zip = await writeZip(
        't.zip', (TestZipBuilder()..addStored('/etc/passwd', [1])).build());
    await expectLater(reader.preflight(zip), packageFailure('absolute path'));
  });

  test('rejects duplicate normalized paths', () async {
    final builder = TestZipBuilder()
      ..addStored('article.json', [1])
      ..addStored('article.json', [2]);
    final zip = await writeZip('t.zip', builder.build());
    await expectLater(reader.preflight(zip), packageFailure('duplicate path'));
  });

  test('rejects directory entries', () async {
    final zip = await writeZip(
        't.zip', (TestZipBuilder()..addStored('audio/', const [])).build());
    await expectLater(reader.preflight(zip), packageFailure('unsafe path'));
  });

  test('rejects encrypted entries', () async {
    final zip = await writeZip(
        't.zip',
        (TestZipBuilder()..addStored('a.json', [1], flags: 0x1)).build());
    await expectLater(reader.preflight(zip), packageFailure('encrypted'));
  });

  test('rejects symlink entries via unix mode', () async {
    const symlinkMode = 0xA1FF; // S_IFLNK | 0777
    final zip = await writeZip(
        't.zip',
        (TestZipBuilder()..addStored('a.json', [1], unixMode: symlinkMode))
            .build());
    await expectLater(
        reader.preflight(zip), packageFailure('non-regular file'));
  });

  test('rejects declared per-entry size above the limit before extraction',
      () async {
    final builder = TestZipBuilder()
      ..addDeflated('big.bin', [1, 2, 3],
          declaredUncompressedSize: SecureZipReader.maxEntryBytes + 1);
    final zip = await writeZip('t.zip', builder.build());
    await expectLater(
      reader.preflight(zip),
      throwsA(isA<AppFailure>()
          .having((f) => f.kind, 'kind', FailureKind.resourceLimit)
          .having((f) => f.message, 'message', contains('entry too large'))),
    );
  });

  test('rejects too many entries', () async {
    final builder = TestZipBuilder();
    for (var i = 0; i < SecureZipReader.maxEntries + 1; i++) {
      builder.addStored('f$i.txt', [i]);
    }
    final zip = await writeZip('t.zip', builder.build());
    await expectLater(reader.preflight(zip), packageFailure('too many entries'));
  });

  test('rejects extraction when actual bytes differ from the declaration',
      () async {
    final builder = TestZipBuilder()
      ..addDeflated('a.json', 'short'.codeUnits,
          declaredUncompressedSize: 100);
    final zip = await writeZip('t.zip', builder.build());
    final entry = (await reader.preflight(zip)).single;
    await expectLater(
      reader.extractEntry(zip, entry, File(p.join(temp.path, 'a.json'))),
      packageFailure('size mismatch after extraction'),
    );
  });
}
