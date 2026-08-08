import 'dart:async';

import 'package:just_audio/just_audio.dart';

import '../../../platform/logging/app_logger.dart';
import '../application/playback_engine.dart';

/// just_audio adapter: local M4A file, clip and continuous playback.
/// All plugin types stay behind this boundary (architecture §6.4).
class JustAudioEngine implements PlaybackEngine {
  JustAudioEngine({AppLogger? logger})
      : _player = AudioPlayer(),
        _logger = logger ?? const AppLogger('playback');

  final AudioPlayer _player;
  final AppLogger _logger;

  @override
  Future<void> playClip({
    required String filePath,
    required Duration start,
    required Duration end,
  }) async {
    final source = ClippingAudioSource(
      start: start,
      end: end,
      child: AudioSource.file(filePath),
    );
    await _player.setAudioSource(source);
    _issuePlayback();
  }

  @override
  Future<void> playFrom({
    required String filePath,
    required Duration start,
  }) async {
    await _player.setAudioSource(AudioSource.file(filePath));
    await _player.seek(start);
    _issuePlayback();
  }

  /// Issues the play request without awaiting it. just_audio's `play()` future
  /// resolves only when playback ends or is paused/stopped, so awaiting it here
  /// would block the command future until the clip finishes — the controller's
  /// command-acceptance token must resolve when the request is issued, and
  /// natural completion is reported separately via [completionStream]. Load/seek
  /// errors surface from the awaited calls above and propagate to the caller;
  /// mid-playback decode errors land here and are logged (they are not part of
  /// any command future the caller awaits).
  void _issuePlayback() {
    unawaited(
      _player.play().catchError((Object error, StackTrace _) {
        _logger.error('playback.play_failed', {'error': '$error'});
      }),
    );
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() async {
    _issuePlayback();
  }

  @override
  Future<void> stop() => _player.stop();

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<void> get completionStream => _player.processingStateStream
      .where((s) => s == ProcessingState.completed)
      .map((_) {});

  @override
  Future<void> dispose() => _player.dispose();
}
