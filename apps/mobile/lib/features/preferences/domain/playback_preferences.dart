/// Global playback behavior preferences.
class PlaybackPreferences {
  const PlaybackPreferences({this.interruptBackgroundAudio = true});

  /// Requests the strongest short-lived Android audio focus before playback.
  /// The request is best-effort: playback continues when focus is unavailable.
  final bool interruptBackgroundAudio;

  PlaybackPreferences copyWith({bool? interruptBackgroundAudio}) =>
      PlaybackPreferences(
        interruptBackgroundAudio:
            interruptBackgroundAudio ?? this.interruptBackgroundAudio,
      );
}
