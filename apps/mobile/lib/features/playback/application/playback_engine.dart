/// Port to the concrete audio player. Only the infrastructure adapter knows
/// about just_audio; the controller talks to this boundary.
abstract class PlaybackEngine {
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

  /// Current playback position (within the clip for [playClip]).
  Stream<Duration> get positionStream;

  /// Fires when playback completes by reaching the clip/file end.
  Stream<void> get completionStream;

  Future<void> dispose();
}
