import 'dart:async';

import '../../../shared_kernel/content_identity.dart';
import '../../library/application/library_service.dart';
import '../domain/lease_registry.dart';
import '../domain/playback_models.dart';
import '../domain/playback_source_port.dart';

/// Resolves a precise [ArticleRef] to a leased, immutable artifact plus sentence
/// boundaries by reading the installed content from `library` (design §4.3
/// internal seam). Pins the audio file in [LeaseRegistry] for the session's
/// lifetime; on release, hands back to `library` so any deferred cleanup runs.
///
/// MVP has no resume, so a request whose ref no longer matches the currently
/// installed version fails fast instead of leasing a half-version whose DB rows
/// an upgrade already replaced.
class LibraryPlaybackSourceAdapter implements PlaybackSourcePort {
  LibraryPlaybackSourceAdapter({
    required LibraryService library,
    required LeaseRegistry registry,
  }) : _library = library,
       _registry = registry;

  final LibraryService _library;
  final LeaseRegistry _registry;

  @override
  Future<PlaybackSourceLease> acquire(ArticleRef ref) async {
    final content = _library.getContent(ref.articleId);
    if (content == null) {
      throw StateError('playback.source.not_installed: $ref');
    }
    if (content.article.ref != ref) {
      throw StateError(
        'playback.source.stale_ref: requested $ref, current ${content.article.ref}',
      );
    }
    final audioFilePath = content.audioFilePath;
    final narration = content.article.narration;
    // Reading-only articles never fake an audio path; playback must fail
    // clearly instead of leasing a missing file (lightweight-readpack §7.2).
    if (audioFilePath == null || narration == null) {
      throw StateError('playback.source.no_narration: $ref');
    }
    final labels = content.sentenceLabels;
    _registry.pin(articleId: ref.articleId, path: audioFilePath);
    return PlaybackSourceLease(
      articleRef: ref,
      title: content.article.title,
      author: content.article.author,
      audioFilePath: audioFilePath,
      totalDuration: Duration(milliseconds: narration.durationMs),
      ranges: [
        for (final sentence in content.sentences)
          if (sentence.hasAudio)
            SentenceAudioRange(
              sentenceId: sentence.sentenceId,
              startMs: sentence.audioStartMs!,
              endMs: sentence.audioEndMs!,
              label: labels[sentence.sentenceId] ?? '',
            ),
      ],
    );
  }

  @override
  void release(PlaybackSourceLease lease) {
    _registry.unpin(lease.audioFilePath);
    // Best-effort retry of any cleanup deferred while this artifact was leased.
    // Failure is logged by the library; it does not affect the next session.
    unawaited(_library.retryCleanup(lease.articleRef));
  }
}
