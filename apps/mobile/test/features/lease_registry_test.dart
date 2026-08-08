import 'package:engirdle_mobile/features/playback/domain/lease_registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-process artifact lease refcount (design §6.3).
void main() {
  late LeaseRegistry registry;

  setUp(() => registry = LeaseRegistry());

  group('path leases', () {
    test('pin then unpin releases the path', () {
      registry.pin(articleId: 'a1', path: '/tmp/a1/audio/article.m4a');
      expect(registry.isLeased('/tmp/a1/audio/article.m4a'), isTrue);
      registry.unpin('/tmp/a1/audio/article.m4a');
      expect(registry.isLeased('/tmp/a1/audio/article.m4a'), isFalse);
    });

    test('refcount: two pins require two unpins', () {
      registry.pin(articleId: 'a1', path: '/p');
      registry.pin(articleId: 'a1', path: '/p');
      registry.unpin('/p');
      expect(registry.isLeased('/p'), isTrue);
      registry.unpin('/p');
      expect(registry.isLeased('/p'), isFalse);
    });

    test('unpin of an unknown path is a no-op', () {
      registry.unpin('/never-pinned');
      expect(registry.isLeased('/never-pinned'), isFalse);
    });
  });

  group('directory guard', () {
    test('a pinned audio file leases the artifact directory that contains it',
        () {
      registry.pin(
        articleId: 'a1',
        path: '/data/articles/a1/1/0/audio/article.m4a',
      );
      expect(registry.isLeasedWithin('/data/articles/a1/1/0'), isTrue);
      expect(registry.isLeasedWithin('/data/articles/a1/2/0'), isFalse);
    });

    test('releasing the file clears the directory lease', () {
      registry.pin(articleId: 'a1', path: '/d/a1/1/0/audio/article.m4a');
      registry.unpin('/d/a1/1/0/audio/article.m4a');
      expect(registry.isLeasedWithin('/d/a1/1/0'), isFalse);
    });
  });

  group('article guard', () {
    test('isLeasedArticle tracks the owning article', () {
      registry.pin(articleId: 'a1', path: '/x/a1.m4a');
      expect(registry.isLeasedArticle('a1'), isTrue);
      expect(registry.isLeasedArticle('a2'), isFalse);
      registry.unpin('/x/a1.m4a');
      expect(registry.isLeasedArticle('a1'), isFalse);
    });
  });
}
