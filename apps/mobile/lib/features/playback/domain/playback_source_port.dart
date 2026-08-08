import '../../../shared_kernel/content_identity.dart';
import 'playback_models.dart';

/// An immutable, leased view of the exact article artifact the active session
/// locked (design §5.1). Lifetime covers Preparing, Playing and Paused; the
/// audio path is pinned in the [LeaseRegistry] until [PlaybackSourcePort.release]
/// runs. The file path never leaves the playback module.
class PlaybackSourceLease {
  const PlaybackSourceLease({
    required this.articleRef,
    required this.title,
    this.author,
    required this.audioFilePath,
    required this.totalDuration,
    required this.ranges,
  });

  final ArticleRef articleRef;
  final String title;
  final String? author;
  final String audioFilePath;
  final Duration totalDuration;

  /// Ordered sentence boundaries (strictly increasing by start), captured at
  /// acquire time so an upgrade cannot change the sounding session's timeline.
  final List<SentenceAudioRange> ranges;
}

/// Internal seam (design §4.3): resolves a precise [ArticleRef] to a leased,
/// immutable artifact plus sentence boundaries. Keeps the upgrade/delete
/// ownership rules inside `library` while the coordinator stays version-agnostic.
abstract class PlaybackSourcePort {
  /// Resolves and pins [ref]. Throws if the version is no longer installed
  /// (stale ref) or the artifact is missing; the coordinator maps a throw to a
  /// failed idle session.
  Future<PlaybackSourceLease> acquire(ArticleRef ref);

  /// Releases the lease and lets `library` retry any deferred cleanup.
  void release(PlaybackSourceLease lease);
}

/// Locates the sentence covering [position] in [ranges] (which must be sorted by
/// start). Binary search avoids a per-position linear scan over long articles
/// (design §5.1).
SentenceAudioRange? sentenceContaining(
  List<SentenceAudioRange> ranges,
  Duration position,
) {
  if (ranges.isEmpty) return null;
  final ms = position.inMilliseconds;
  var lo = 0;
  var hi = ranges.length - 1;
  var result = -1;
  while (lo <= hi) {
    final mid = (lo + hi) ~/ 2;
    if (ranges[mid].startMs <= ms) {
      result = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return result < 0 ? null : ranges[result];
}
