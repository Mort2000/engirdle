import 'package:audio_service/audio_service.dart';

import '../application/playback_controller.dart';
import '../domain/playback_models.dart';

/// Android foreground media Service / MediaSession adapter (design §4.3/§7.2).
///
/// It holds no domain state of its own: system commands (notification,
/// lock-screen, earphone) are forwarded to the [PlaybackController]
/// coordinator, and the coordinator's [PlaybackSnapshot] is projected into the
/// audio_service [PlaybackState] and [MediaItem] that the system notification,
/// lock screen and Flutter UI all consume. Metadata exposes only the article
/// title/author, mode and current sentence — never body text, translation, the
/// file path or LAN address (design §5.3).
class EngirdleAudioHandler extends BaseAudioHandler {
  EngirdleAudioHandler(this._coordinator);

  final PlaybackController _coordinator;
  bool _bound = false;

  /// Subscribes to the coordinator's snapshot and publishes the initial state.
  /// Call once after [AudioService.init]. The handler lives for the process;
  /// there is no teardown — the coordinator is disposed with the app.
  void bind() {
    if (_bound) return;
    _bound = true;
    _coordinator.state.addListener(_onSnapshot);
    _onSnapshot();
  }

  void _onSnapshot() {
    final snapshot = _coordinator.state.value;
    mediaItem.add(mediaItemFromSnapshot(snapshot));
    playbackState.add(playbackStateFromSnapshot(snapshot));
  }

  // ---- System media commands → coordinator (design §5.3) ----

  @override
  Future<void> play() async {
    // Resume only; never auto-create a session from history when idle (§9.1).
    if (_coordinator.state.value.phase == PlaybackPhase.paused) {
      await _coordinator.resume();
    }
  }

  @override
  Future<void> pause() => _coordinator.pause();

  @override
  Future<void> stop() => _coordinator.stop();

  /// Headset/lock-screen main button: toggle play/pause. No-op when idle.
  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    if (button != MediaButton.media) return;
    switch (_coordinator.state.value.phase) {
      case PlaybackPhase.playing:
        await _coordinator.pause();
      case PlaybackPhase.paused:
        await _coordinator.resume();
      case PlaybackPhase.idle:
      case PlaybackPhase.preparing:
        break;
    }
  }

  /// Swipe-from-recents keeps an active session; otherwise stops and releases.
  @override
  Future<void> onTaskRemoved() async {
    final phase = _coordinator.state.value.phase;
    if (phase != PlaybackPhase.preparing && phase != PlaybackPhase.playing) {
      await _coordinator.stop();
    }
  }

  /// Notification dismissed → stop and release (design §7.2).
  @override
  Future<void> onNotificationDeleted() => _coordinator.stop();
}

/// Projects the coordinator snapshot to a [MediaItem]. The id is a logical
/// article id, never the audio file path; only title/author/mode/sentence are
/// exposed (design §5.3).
MediaItem mediaItemFromSnapshot(PlaybackSnapshot snapshot) {
  if (!snapshot.isActive) return const MediaItem(id: _emptyMediaId, title: '');
  final subtitle = switch (snapshot.mode) {
    PlaybackMode.sentence => '单句 · ${snapshot.currentLabel ?? ''}',
    PlaybackMode.continuous => '连续 · 当前${snapshot.currentLabel ?? ''}',
    null => '',
  };
  return MediaItem(
    id: '$_articleMediaIdPrefix${snapshot.articleRef?.articleId ?? ''}',
    title: snapshot.title ?? 'Engirdle',
    artist: snapshot.author ?? 'Engirdle',
    album: 'Engirdle',
    duration: snapshot.playableDuration == Duration.zero
        ? null
        : snapshot.playableDuration,
    displaySubtitle: subtitle,
  );
}

/// Projects the snapshot to a [PlaybackState]. Only play/pause/stop are
/// declared as available actions (design §3.2/§9.1).
PlaybackState playbackStateFromSnapshot(PlaybackSnapshot snapshot) {
  final processingState = switch (snapshot.phase) {
    PlaybackPhase.idle => AudioProcessingState.idle,
    PlaybackPhase.preparing => AudioProcessingState.loading,
    PlaybackPhase.playing => AudioProcessingState.ready,
    PlaybackPhase.paused => AudioProcessingState.ready,
  };
  final playing = snapshot.phase == PlaybackPhase.playing;
  final controls = <MediaControl>[
    if (playing)
      MediaControl.pause
    else if (snapshot.phase == PlaybackPhase.paused)
      MediaControl.play,
    if (snapshot.isActive) MediaControl.stop,
  ];
  return PlaybackState(
    controls: controls,
    systemActions: const {
      MediaAction.play,
      MediaAction.pause,
      MediaAction.stop,
    },
    // Indices must stay within controls (empty while idle): fall back to the
    // plugin default when fewer than two controls exist.
    androidCompactActionIndices: controls.length >= 2 ? const [0, 1] : null,
    processingState: processingState,
    playing: playing,
    updatePosition: snapshot.position,
    bufferedPosition: snapshot.position,
    speed: 1.0,
  );
}

const _emptyMediaId = 'engirdle:none';
const _articleMediaIdPrefix = 'engirdle:article:';
