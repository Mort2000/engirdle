import 'dart:async';

import 'package:engirdle_mobile/features/playback/application/playback_controller.dart';
import 'package:engirdle_mobile/features/playback/application/playback_engine.dart';
import 'package:engirdle_mobile/features/playback/domain/playback_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Session token protocol (design §8.4): supersession, completion routing,
/// failure handling, and check-then-await-then-write revalidation of the
/// single playback session.
void main() {
  late FakePlaybackEngine engine;
  late PlaybackController controller;

  setUp(() {
    engine = FakePlaybackEngine();
    controller = PlaybackController(engine: engine);
    controller.attachArticle('/tmp/audio.m4a', const [
      SentenceAudioRange(
        sentenceId: 's1',
        startMs: 0,
        endMs: 1000,
        label: '第 1 段第 1 句',
      ),
      SentenceAudioRange(
        sentenceId: 's2',
        startMs: 1000,
        endMs: 2000,
        label: '第 1 段第 2 句',
      ),
    ]);
  });

  tearDown(() => controller.dispose());

  group('failure handling', () {
    test('a failed command idles the session and never rethrows', () async {
      engine.playClipError = StateError('decoder boom');
      await controller.playSentence('s1');
      expect(controller.state.value.status, PlaybackStatus.idle);
      expect(engine.stopCalls, 1);
    });

    test('a superseded command failure is dropped silently', () async {
      engine.autoComplete = false;
      final stale = controller.playSentence('s1');
      final live = controller.playSentence('s2');
      engine.pendingPlayClips[1].complete();
      await live;
      engine.pendingPlayClips[0].completeError(StateError('stale failure'));
      await stale;
      expect(controller.state.value.status, PlaybackStatus.playing);
      expect(controller.state.value.currentSentenceId, 's2');
      expect(engine.stopCalls, 0);
    });
  });

  group('completion routing', () {
    test('completion of the settled session returns to idle', () async {
      await controller.playSentence('s1');
      expect(controller.state.value.status, PlaybackStatus.playing);
      engine.emitCompletion();
      await pumpEventQueue();
      expect(controller.state.value.status, PlaybackStatus.idle);
    });

    test('a stale clip completion cannot idle an in-flight command', () async {
      await controller.playSentence('s1'); // settles
      engine.autoComplete = false;
      final live = controller.playSentence('s2'); // inside the engine await
      // The replaced clip reaches its natural end inside that await window.
      engine.emitCompletion();
      await pumpEventQueue();
      expect(controller.state.value.status, PlaybackStatus.playing);
      expect(controller.state.value.currentSentenceId, 's2');
      // Once s2 settles, its own completion ends the session normally.
      engine.pendingPlayClips.single.complete();
      await live;
      engine.emitCompletion();
      await pumpEventQueue();
      expect(controller.state.value.status, PlaybackStatus.idle);
    });
  });

  group('check-then-await-then-write revalidation', () {
    test('stop raced by a new command does not kill the new session', () async {
      await controller.playSentence('s1');
      engine.autoComplete = false;
      final stopping = controller.stop();
      final live = controller.playSentence('s2');
      engine.pendingPlayClips.single.complete();
      await live;
      engine.pendingStops.single.complete();
      await stopping;
      expect(controller.state.value.status, PlaybackStatus.playing);
      expect(controller.state.value.currentSentenceId, 's2');
    });

    test('pause resolving after stop leaves no zombie paused state', () async {
      await controller.playSentence('s1');
      engine.autoComplete = false;
      final pausing = controller.pause();
      final stopping = controller.stop();
      engine.pendingStops.single.complete();
      await stopping;
      engine.pendingPauses.single.complete();
      await pausing;
      expect(controller.state.value.status, PlaybackStatus.idle);
    });

    test('resume resolving after stop leaves the session idle', () async {
      await controller.playSentence('s1');
      await controller.pause();
      expect(controller.state.value.status, PlaybackStatus.paused);
      engine.autoComplete = false;
      final resuming = controller.resume();
      final stopping = controller.stop();
      engine.pendingStops.single.complete();
      await stopping;
      engine.pendingResumes.single.complete();
      await resuming;
      expect(controller.state.value.status, PlaybackStatus.idle);
    });
  });
}

/// Controllable fake: with [autoComplete] off, every engine call parks a
/// completer the test resolves explicitly to script async interleavings.
class FakePlaybackEngine implements PlaybackEngine {
  final _position = StreamController<Duration>.broadcast();
  final _completion = StreamController<void>.broadcast();

  bool autoComplete = true;
  Object? playClipError;
  int stopCalls = 0;

  final pendingPlayClips = <Completer<void>>[];
  final pendingPlayFroms = <Completer<void>>[];
  final pendingPauses = <Completer<void>>[];
  final pendingResumes = <Completer<void>>[];
  final pendingStops = <Completer<void>>[];

  void emitCompletion() => _completion.add(null);

  @override
  Future<void> playClip({
    required String filePath,
    required Duration start,
    required Duration end,
  }) {
    final error = playClipError;
    if (error != null) return Future.error(error);
    if (autoComplete) return Future.value();
    final completer = Completer<void>();
    pendingPlayClips.add(completer);
    return completer.future;
  }

  @override
  Future<void> playFrom({required String filePath, required Duration start}) {
    if (autoComplete) return Future.value();
    final completer = Completer<void>();
    pendingPlayFroms.add(completer);
    return completer.future;
  }

  @override
  Future<void> pause() {
    if (autoComplete) return Future.value();
    final completer = Completer<void>();
    pendingPauses.add(completer);
    return completer.future;
  }

  @override
  Future<void> resume() {
    if (autoComplete) return Future.value();
    final completer = Completer<void>();
    pendingResumes.add(completer);
    return completer.future;
  }

  @override
  Future<void> stop() {
    stopCalls++;
    if (autoComplete) return Future.value();
    final completer = Completer<void>();
    pendingStops.add(completer);
    return completer.future;
  }

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<void> get completionStream => _completion.stream;

  @override
  Future<void> dispose() async {
    await _position.close();
    await _completion.close();
  }
}
