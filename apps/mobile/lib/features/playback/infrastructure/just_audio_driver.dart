import 'dart:async';

import 'package:just_audio/just_audio.dart';

import '../../../platform/logging/app_logger.dart';
import '../application/playback_driver.dart';

/// just_audio adapter: local M4A file, clip and continuous playback. All plugin
/// types stay behind this boundary (architecture §6.4).
///
/// `handleInterruptions: false` turns off just_audio's built-in pause/resume so
/// the coordinator owns interruption policy (design §6.2); audio-session
/// activation and speech attributes stay with just_audio's defaults. The
/// player's position/playing/processing/error signals are merged into a single
/// [PlaybackDriverEvent] stream for the coordinator to reduce.
class JustAudioDriver implements PlaybackDriver {
  JustAudioDriver({AppLogger? logger})
      : _player = AudioPlayer(handleInterruptions: false),
        _logger = logger ?? const AppLogger('playback');

  final AudioPlayer _player;
  final AppLogger _logger;

  final _events = StreamController<PlaybackDriverEvent>.broadcast();
  late final StreamSubscription _processingSub;
  late final StreamSubscription _errorSub;
  late final StreamSubscription _positionSub;

  var _wired = false;

  void _wire() {
    if (_wired) return;
    _wired = true;
    _processingSub = _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) _events.add(DriverCompleted());
    });
    _errorSub = _player.errorStream.listen(
      (error) {
        _logger.error('playback.driver_error', {'error': '$error'});
        _events.add(DriverError(error));
      },
    );
    _positionSub = _player.positionStream.listen(
      (position) => _events.add(DriverPosition(position)),
    );
  }

  @override
  Future<void> playClip({
    required String filePath,
    required Duration start,
    required Duration end,
  }) async {
    _wire();
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
    _wire();
    await _player.setAudioSource(AudioSource.file(filePath));
    await _player.seek(start);
    _issuePlayback();
  }

  /// Issues the play request without awaiting it. just_audio's `play()` future
  /// resolves only when playback ends or is paused/stopped, so awaiting it here
  /// would block the command future until the clip finishes — the coordinator's
  /// command-acceptance token must resolve when the request is issued, and
  /// natural completion is reported separately via [DriverCompleted]. Load/seek
  /// errors surface from the awaited calls above and propagate to the caller;
  /// mid-playback errors land on [DriverError].
  void _issuePlayback() {
    unawaited(
      _player.play().catchError((Object error, StackTrace _) {
        _logger.error('playback.play_failed', {'error': '$error'});
        _events.add(DriverError(error));
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
  Stream<PlaybackDriverEvent> get events {
    _wire();
    return _events.stream;
  }

  @override
  Future<void> dispose() async {
    if (_wired) {
      await _processingSub.cancel();
      await _errorSub.cancel();
      await _positionSub.cancel();
    }
    await _events.close();
    await _player.dispose();
  }
}
