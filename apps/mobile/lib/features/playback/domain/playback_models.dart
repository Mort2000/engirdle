/// Playback domain model (design §8.4): one player instance, one session,
/// sentence-clipped or continuous mode.
enum PlaybackMode { sentence, continuous }

enum PlaybackStatus { idle, playing, paused }

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

/// Immutable view state consumed by the playback bar and reader highlight.
class PlaybackViewState {
  const PlaybackViewState({
    required this.status,
    this.mode,
    this.currentSentenceId,
    this.currentLabel,
    this.position = Duration.zero,
    this.clipLength = Duration.zero,
    this.startLabel,
  });

  const PlaybackViewState.idle()
      : status = PlaybackStatus.idle,
        mode = null,
        currentSentenceId = null,
        currentLabel = null,
        position = Duration.zero,
        clipLength = Duration.zero,
        startLabel = null;

  final PlaybackStatus status;
  final PlaybackMode? mode;

  /// Sentence currently sounding (drives the reader highlight).
  final String? currentSentenceId;
  final String? currentLabel;

  /// Position within the current clip (sentence mode) or file (continuous).
  final Duration position;

  /// Clip length for sentence mode; zero otherwise.
  final Duration clipLength;

  /// Continuous mode: where playback started (「起点：第 X 段第 Y 句」).
  final String? startLabel;

  bool get isActive => status != PlaybackStatus.idle;

  PlaybackViewState copyWith({
    PlaybackStatus? status,
    PlaybackMode? mode,
    String? currentSentenceId,
    String? currentLabel,
    Duration? position,
    Duration? clipLength,
    String? startLabel,
    bool clearSession = false,
  }) {
    if (clearSession) return const PlaybackViewState.idle();
    return PlaybackViewState(
      status: status ?? this.status,
      mode: mode ?? this.mode,
      currentSentenceId: currentSentenceId ?? this.currentSentenceId,
      currentLabel: currentLabel ?? this.currentLabel,
      position: position ?? this.position,
      clipLength: clipLength ?? this.clipLength,
      startLabel: startLabel ?? this.startLabel,
    );
  }
}

/// One-shot UI events (snackbars). UX-A2: the replacement notice fires only
/// when a *continuous* session is replaced by a new play request.
sealed class PlaybackEvent {}

class ContinuousSessionReplaced extends PlaybackEvent {}
