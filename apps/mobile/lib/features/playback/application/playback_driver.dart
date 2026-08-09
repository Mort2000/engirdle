import 'dart:async';

/// Observable events from the concrete player, merged into one stream so the
/// coordinator reduces them through a single token-validated path (design
/// §8: evolve PlaybackEngine into a PlaybackDriver that unifies
/// position/processing/completion/error). No plugin types leak past this
/// boundary. (The player's own playing/paused echoes are deliberately not
/// surfaced: the coordinator drives pause/resume and would only have to
/// reconcile them back, risking a paused flash on natural completion.)
sealed class PlaybackDriverEvent {}

/// Playback reached the clip/file end naturally (distinct from the issue-time
/// resolution of the play command future).
class DriverCompleted extends PlaybackDriverEvent {}

/// A decode/load or platform error after the command was issued.
class DriverError extends PlaybackDriverEvent {
  DriverError(this.error);
  final Object error;
}

class DriverPosition extends PlaybackDriverEvent {
  DriverPosition(this.position);
  final Duration position;
}

/// Port to the concrete audio player (design §4.3 internal seam). Only the
/// infrastructure adapter knows about just_audio; the coordinator talks to
/// this boundary.
///
/// Contract: [playClip]/[playFrom] resolve once the play request has been
/// *issued* (mirroring just_audio, whose `play()` future resolves at request
/// time, not at end). Natural completion is reported separately via
/// [DriverCompleted]; mid-playback failures via [DriverError].
abstract class PlaybackDriver {
  /// Plays `[start, end)` of [filePath], then completes naturally.
  Future<void> playClip({
    required String filePath,
    required Duration start,
    required Duration end,
  });

  /// Plays [filePath] from [start] to the end of the file (sentence and
  /// paragraph pauses are part of the recording, design §4.6).
  Future<void> playFrom({
    required String filePath,
    required Duration start,
  });

  Future<void> pause();

  Future<void> resume();

  Future<void> stop();

  /// Merged observable events (playing/paused/completed/error/position).
  Stream<PlaybackDriverEvent> get events;

  Future<void> dispose();
}
