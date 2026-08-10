/// Read-only playback settings consumed by the playback coordinator.
abstract interface class PlaybackSettingsPort {
  bool get interruptBackgroundAudio;
}
