import 'dart:async';

import 'package:just_audio/just_audio.dart';

import '../application/playback_engine.dart';

/// just_audio adapter: local M4A file, clip and continuous playback.
/// All plugin types stay behind this boundary (architecture §6.4).
class JustAudioEngine implements PlaybackEngine {
  JustAudioEngine() : _player = AudioPlayer();

  final AudioPlayer _player;

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
    await _player.play();
  }

  @override
  Future<void> playFrom({
    required String filePath,
    required Duration start,
  }) async {
    await _player.setAudioSource(AudioSource.file(filePath));
    await _player.seek(start);
    await _player.play();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.play();

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
