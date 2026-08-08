import '../../../shared_kernel/content_identity.dart';

/// Playback domain model (design §5.1): one player instance, one session,
/// sentence-clipped or continuous mode. The coordinator is the single source
/// of truth; UI and system-media adapters both consume [PlaybackSnapshot].
enum PlaybackMode { sentence, continuous }

/// Session lifecycle phases (design §5.2). Activity foreground/background and
/// screen on/off are *not* phase transitions.
enum PlaybackPhase { idle, preparing, playing, paused }

/// A sentence's legal audio interval plus its user-facing ordinal label
/// (「第 X 段第 Y 句」, computed from reading order — opaque IDs are never
/// parsed for display).
class SentenceAudioRange {
  const SentenceAudioRange({
    required this.sentenceId,
    required this.startMs,
    required this.endMs,
    required this.label,
  });

  final String sentenceId;
  final int startMs;
  final int endMs;
  final String label;

  Duration get start => Duration(milliseconds: startMs);
  Duration get end => Duration(milliseconds: endMs);
}

/// The single play request callers learn (design §4.2). It carries the full
/// article identity (so an upgrade cannot silently switch the active session's
/// audio) plus the starting sentence and mode — never a file path or ms
/// boundary. The coordinator resolves the exact artifact via PlaybackSourcePort.
class PlaybackRequest {
  const PlaybackRequest({
    required this.articleRef,
    required this.sentenceId,
    required this.mode,
  });

  final ArticleRef articleRef;
  final String sentenceId;
  final PlaybackMode mode;
}

/// Immutable view state consumed by the playback bar, reader highlight and the
/// system-media adapter (design §5.1). This is the only state input for both
/// UI and system media.
class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.sessionToken,
    this.articleRef,
    this.title,
    this.author,
    this.mode,
    required this.phase,
    this.currentSentenceId,
    this.currentLabel,
    this.startLabel,
    this.sentenceOrdinal,
    this.position = Duration.zero,
    this.playableDuration = Duration.zero,
  });

  const PlaybackSnapshot.idle()
      : sessionToken = 0,
        articleRef = null,
        title = null,
        author = null,
        mode = null,
        phase = PlaybackPhase.idle,
        currentSentenceId = null,
        currentLabel = null,
        startLabel = null,
        sentenceOrdinal = null,
        position = Duration.zero,
        playableDuration = Duration.zero;

  /// Monotonic id of the command owning this snapshot (design §5.2 token
  /// protocol). 0 = no session.
  final int sessionToken;
  final ArticleRef? articleRef;

  /// Article title / author for the reader header and the media notification.
  final String? title;
  final String? author;

  final PlaybackMode? mode;
  final PlaybackPhase phase;

  /// Sentence currently sounding (drives the reader highlight).
  final String? currentSentenceId;
  final String? currentLabel;

  /// Continuous mode: where playback started (「起点：第 X 段第 Y 句」).
  final String? startLabel;

  /// 1-based ordinal of the sounding sentence, for media metadata.
  final int? sentenceOrdinal;

  /// Position within the current clip (sentence mode) or file (continuous).
  final Duration position;

  /// Clip length for sentence mode; total article duration for continuous.
  final Duration playableDuration;

  bool get isActive => phase != PlaybackPhase.idle;

  PlaybackSnapshot copyWith({
    int? sessionToken,
    ArticleRef? articleRef,
    String? title,
    String? author,
    PlaybackMode? mode,
    PlaybackPhase? phase,
    String? currentSentenceId,
    String? currentLabel,
    String? startLabel,
    int? sentenceOrdinal,
    Duration? position,
    Duration? playableDuration,
    bool clearSession = false,
  }) {
    if (clearSession) return const PlaybackSnapshot.idle();
    return PlaybackSnapshot(
      sessionToken: sessionToken ?? this.sessionToken,
      articleRef: articleRef ?? this.articleRef,
      title: title ?? this.title,
      author: author ?? this.author,
      mode: mode ?? this.mode,
      phase: phase ?? this.phase,
      currentSentenceId: currentSentenceId ?? this.currentSentenceId,
      currentLabel: currentLabel ?? this.currentLabel,
      startLabel: startLabel ?? this.startLabel,
      sentenceOrdinal: sentenceOrdinal ?? this.sentenceOrdinal,
      position: position ?? this.position,
      playableDuration: playableDuration ?? this.playableDuration,
    );
  }
}

/// One-shot UI events (snackbars). UX-A2: the replacement notice fires only
/// when a *continuous* session is replaced by a new play request.
sealed class PlaybackEvent {
  const PlaybackEvent();
}

class ContinuousSessionReplaced extends PlaybackEvent {
  const ContinuousSessionReplaced();
}

/// A session could not start or failed mid-playback (decode error, focus
/// denied, source lease failure). The UI surfaces a short message; the session
/// is already back to idle by the time this fires.
class PlaybackFailed extends PlaybackEvent {
  const PlaybackFailed(this.reason);
  final String reason;
}
