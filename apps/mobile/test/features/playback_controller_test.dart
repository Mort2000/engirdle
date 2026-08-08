import 'dart:async';

import 'package:engirdle_mobile/features/playback/application/audio_focus_port.dart';
import 'package:engirdle_mobile/features/playback/application/playback_controller.dart';
import 'package:engirdle_mobile/features/playback/application/playback_driver.dart';
import 'package:engirdle_mobile/features/playback/domain/playback_models.dart';
import 'package:engirdle_mobile/features/playback/domain/playback_source_port.dart';
import 'package:engirdle_mobile/shared_kernel/content_identity.dart';
import 'package:flutter_test/flutter_test.dart';

/// Coordinator session protocol (design §5.2): supersession, completion/error
/// routing, failure handling, check-then-await-then-write revalidation, the
/// source lease lifecycle, and the audio-focus interruption state machine.
void main() {
  final ref = ArticleRef(articleId: 'a1', revision: 1, artifactRevision: 1);

  const ranges = [
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
  ];

  PlaybackRequest sentence(String id) =>
      PlaybackRequest(articleRef: ref, sentenceId: id, mode: PlaybackMode.sentence);

  late ControllableDriver driver;
  late FakeSourcePort source;
  late ControllableFocusPort focus;
  late PlaybackController controller;

  setUp(() {
    driver = ControllableDriver();
    source = FakeSourcePort(ranges: ranges);
    focus = ControllableFocusPort();
    controller = PlaybackController(
      driver: driver,
      sourcePort: source,
      focusPort: focus,
    );
  });

  tearDown(() => controller.dispose());

  group('start lifecycle', () {
    test('a command goes preparing then playing as the driver accepts it',
        () async {
      driver.autoComplete = false;
      final done = controller.start(sentence('s1'));
      // acquire resolves on a microtask; the play call then parks.
      await pumpEventQueue();
      expect(controller.state.value.phase, PlaybackPhase.preparing);
      expect(controller.state.value.mode, PlaybackMode.sentence);
      expect(controller.state.value.currentSentenceId, 's1');

      driver.pendingPlayClips.single.complete();
      await done;
      expect(controller.state.value.phase, PlaybackPhase.playing);
    });

    test('a new start releases the previous lease and supersedes the session',
        () async {
      await controller.start(sentence('s1'));
      expect(source.acquired.single, ref);
      expect(source.released, isEmpty);

      await controller.start(sentence('s2'));
      expect(source.acquired.length, 2);
      // The first session's lease was released when the second began.
      expect(source.released.length, 1);
      expect(controller.state.value.currentSentenceId, 's2');
    });

    test('stop releases the lease and returns to idle', () async {
      await controller.start(sentence('s1'));
      await controller.stop();
      expect(controller.state.value.phase, PlaybackPhase.idle);
      expect(source.released.length, 1);
    });

    test('a continuous request records its start sentence', () async {
      await controller.start(PlaybackRequest(
        articleRef: ref,
        sentenceId: 's1',
        mode: PlaybackMode.continuous,
      ));
      expect(controller.state.value.mode, PlaybackMode.continuous);
      expect(controller.state.value.startLabel, '第 1 段第 1 句');
      expect(controller.state.value.playableDuration,
          const Duration(milliseconds: 2000));
    });
  });

  group('failure handling', () {
    test('a failed command idles the session, fires an event, never rethrows',
        () async {
      driver.playClipError = StateError('decoder boom');
      final events = <PlaybackEvent>[];
      controller.events.listen(events.add);

      await controller.start(sentence('s1'));
      await pumpEventQueue(); // broadcast event delivery is async

      expect(controller.state.value.phase, PlaybackPhase.idle);
      expect(driver.stopCalls, 1);
      expect(events.single, isA<PlaybackFailed>());
      // acquire pinned a lease before play; the failure must release it.
      expect(source.released.length, 1);
    });

    test('an acquire failure idles without pinning or releasing a lease',
        () async {
      source.acquireError = StateError('stale ref');
      final events = <PlaybackEvent>[];
      controller.events.listen(events.add);

      await controller.start(sentence('s1'));
      await pumpEventQueue();

      expect(controller.state.value.phase, PlaybackPhase.idle);
      expect(source.released, isEmpty); // acquire threw before pinning
      expect(events.single, isA<PlaybackFailed>());
    });

    test('a superseded command failure is dropped silently', () async {
      driver.autoComplete = false;
      final stale = controller.start(sentence('s1'));
      await pumpEventQueue(); // s1 past acquire → playClip parked
      final live = controller.start(sentence('s2'));
      await pumpEventQueue(); // s2 past acquire → playClip parked
      driver.pendingPlayClips[1].complete(); // s2 settles → playing
      await live;
      driver.pendingPlayClips[0].completeError(StateError('stale failure'));
      await stale;

      expect(controller.state.value.phase, PlaybackPhase.playing);
      expect(controller.state.value.currentSentenceId, 's2');
      expect(driver.stopCalls, 0);
    });
  });

  group('completion routing', () {
    test('completion of the settled session returns to idle and releases lease',
        () async {
      await controller.start(sentence('s1'));
      expect(controller.state.value.phase, PlaybackPhase.playing);

      driver.emitCompletion();
      await pumpEventQueue();

      expect(controller.state.value.phase, PlaybackPhase.idle);
      expect(source.released.length, 1);
    });

    // Regression: the real driver resolves each command future at issue time
    // and reports completion as a separate event. If a change ever couples
    // them again, the bar would stay "playing" after a clip ends.
    test('each sentence played to its natural end returns to idle', () async {
      await controller.start(sentence('s1'));
      driver.emitCompletion();
      await pumpEventQueue();
      expect(controller.state.value.phase, PlaybackPhase.idle);

      await controller.start(sentence('s2'));
      driver.emitCompletion();
      await pumpEventQueue();
      expect(controller.state.value.phase, PlaybackPhase.idle);
    });

    test('a stale clip completion cannot idle an in-flight command', () async {
      await controller.start(sentence('s1')); // settles
      driver.autoComplete = false;
      final live = controller.start(sentence('s2')); // inside the driver await
      // The replaced clip reaches its natural end inside that await window.
      driver.emitCompletion();
      await pumpEventQueue();
      expect(controller.state.value.phase, PlaybackPhase.preparing);
      expect(controller.state.value.currentSentenceId, 's2');
      // Once s2 settles, its own completion ends the session normally.
      driver.pendingPlayClips.single.complete();
      await live;
      expect(controller.state.value.phase, PlaybackPhase.playing);
      driver.emitCompletion();
      await pumpEventQueue();
      expect(controller.state.value.phase, PlaybackPhase.idle);
    });
  });

  group('check-then-await-then-write revalidation', () {
    test('stop raced by a new command does not kill the new session', () async {
      await controller.start(sentence('s1'));
      driver.autoComplete = false;
      final stopping = controller.stop();
      final live = controller.start(sentence('s2'));
      await pumpEventQueue(); // s2 past acquire → playClip parked
      driver.pendingPlayClips.single.complete();
      await live;
      driver.pendingStops.single.complete();
      await stopping;
      expect(controller.state.value.phase, PlaybackPhase.playing);
      expect(controller.state.value.currentSentenceId, 's2');
    });

    test('pause resolving after stop leaves no zombie paused state', () async {
      await controller.start(sentence('s1'));
      driver.autoComplete = false;
      final pausing = controller.pause();
      final stopping = controller.stop();
      driver.pendingStops.single.complete();
      await stopping;
      driver.pendingPauses.single.complete();
      await pausing;
      expect(controller.state.value.phase, PlaybackPhase.idle);
    });

    test('resume resolving after stop leaves the session idle', () async {
      await controller.start(sentence('s1'));
      await controller.pause();
      expect(controller.state.value.phase, PlaybackPhase.paused);
      driver.autoComplete = false;
      final resuming = controller.resume();
      final stopping = controller.stop();
      driver.pendingStops.single.complete();
      await stopping;
      driver.pendingResumes.single.complete();
      await resuming;
      expect(controller.state.value.phase, PlaybackPhase.idle);
    });
  });

  group('audio focus / interruption state machine', () {
    test('transient loss pauses and regain resumes', () async {
      await controller.start(sentence('s1'));
      focus.emit(TransientFocusLoss());
      await pumpEventQueue();
      expect(controller.state.value.phase, PlaybackPhase.paused);

      focus.emit(FocusRegained());
      await pumpEventQueue();
      expect(controller.state.value.phase, PlaybackPhase.playing);
    });

    test('permanent loss never auto-resumes on regain', () async {
      await controller.start(sentence('s1'));
      focus.emit(PermanentFocusLoss());
      await pumpEventQueue();
      expect(controller.state.value.phase, PlaybackPhase.paused);

      focus.emit(FocusRegained());
      await pumpEventQueue();
      expect(controller.state.value.phase, PlaybackPhase.paused);
    });

    test('becoming noisy pauses and never auto-resumes', () async {
      await controller.start(sentence('s1'));
      focus.emit(BecomingNoisy());
      await pumpEventQueue();
      expect(controller.state.value.phase, PlaybackPhase.paused);

      focus.emit(FocusRegained());
      await pumpEventQueue();
      expect(controller.state.value.phase, PlaybackPhase.paused);
    });

    test('a user pause during a transient loss voids the recovery intent',
        () async {
      await controller.start(sentence('s1'));
      focus.emit(TransientFocusLoss());
      await pumpEventQueue();
      expect(controller.state.value.phase, PlaybackPhase.paused);

      await controller.pause(); // explicit pause takes over
      focus.emit(FocusRegained());
      await pumpEventQueue();
      expect(controller.state.value.phase, PlaybackPhase.paused);
    });
  });

  group('continuous highlight', () {
    test('position maps to the sounding sentence', () async {
      await controller.start(PlaybackRequest(
        articleRef: ref,
        sentenceId: 's1',
        mode: PlaybackMode.continuous,
      ));
      driver.emitPosition(const Duration(milliseconds: 1200)); // within s2
      await pumpEventQueue();
      expect(controller.state.value.currentSentenceId, 's2');
      expect(controller.state.value.sentenceOrdinal, 2);
    });
  });
}

/// Controllable driver: with [autoComplete] off, every call parks a completer
/// the test resolves explicitly to script async interleavings. Mirrors the real
/// driver contract (see JustAudioDriver): the play futures resolve once the
/// request is *issued*, NOT when playback reaches the end — completion is a
/// separate event via [emitCompletion].
class ControllableDriver implements PlaybackDriver {
  final _events = StreamController<PlaybackDriverEvent>.broadcast();

  bool autoComplete = true;
  Object? playClipError;
  int stopCalls = 0;

  final pendingPlayClips = <Completer<void>>[];
  final pendingPlayFroms = <Completer<void>>[];
  final pendingPauses = <Completer<void>>[];
  final pendingResumes = <Completer<void>>[];
  final pendingStops = <Completer<void>>[];

  void emitCompletion() => _events.add(DriverCompleted());
  void emitError(Object error) => _events.add(DriverError(error));
  void emitPosition(Duration position) => _events.add(DriverPosition(position));

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
  Stream<PlaybackDriverEvent> get events => _events.stream;

  @override
  Future<void> dispose() async => _events.close();
}

/// Records acquire/release so tests can assert the lease lifecycle.
class FakeSourcePort implements PlaybackSourcePort {
  FakeSourcePort({this.ranges = const []});

  final List<SentenceAudioRange> ranges;
  Object? acquireError;
  final acquired = <ArticleRef>[];
  final released = <PlaybackSourceLease>[];

  @override
  Future<PlaybackSourceLease> acquire(ArticleRef ref) async {
    if (acquireError != null) throw acquireError!;
    acquired.add(ref);
    return PlaybackSourceLease(
      articleRef: ref,
      title: 'Test Article',
      audioFilePath: '/tmp/audio.m4a',
      totalDuration: const Duration(milliseconds: 2000),
      ranges: ranges,
    );
  }

  @override
  void release(PlaybackSourceLease lease) => released.add(lease);
}

/// Emits focus events the test scripts directly.
class ControllableFocusPort implements AudioFocusPort {
  final _events = StreamController<AudioFocusEvent>.broadcast();

  void emit(AudioFocusEvent event) => _events.add(event);

  @override
  Stream<AudioFocusEvent> get events => _events.stream;
}
