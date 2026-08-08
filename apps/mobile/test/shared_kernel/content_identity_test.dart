import 'package:engirdle_mobile/shared_kernel/content_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const id = '11111111-1111-4111-8111-111111111111';

  ArticleRef ref(int revision, int artifactRevision) => ArticleRef(
      articleId: id, revision: revision, artifactRevision: artifactRevision);

  group('ArticleRef.isOlderThan (MOB-CAT-001)', () {
    test('a higher content revision is newer', () {
      expect(ref(1, 5).isOlderThan(ref(2, 1)), isTrue);
      expect(ref(2, 1).isOlderThan(ref(1, 5)), isFalse);
    });

    test('artifact revision breaks ties on the same content revision', () {
      expect(ref(1, 1).isOlderThan(ref(1, 2)), isTrue);
      expect(ref(1, 2).isOlderThan(ref(1, 1)), isFalse);
    });

    test('identical refs are not older than each other', () {
      expect(ref(3, 3).isOlderThan(ref(3, 3)), isFalse);
    });
  });

  group('ArticleRef equality', () {
    test('same identity compares equal and hashes equal', () {
      expect(ref(1, 2), equals(ref(1, 2)));
      expect(ref(1, 2).hashCode, ref(1, 2).hashCode);
      expect(ref(1, 2), isNot(equals(ref(2, 1))));
      expect(ref(1, 2), isNot(equals(ref(1, 3))));
    });
  });
}
