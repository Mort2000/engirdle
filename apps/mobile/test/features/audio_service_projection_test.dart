import 'package:audio_service/audio_service.dart';
import 'package:engirdle_mobile/features/playback/domain/playback_models.dart';
import 'package:engirdle_mobile/features/playback/infrastructure/audio_service_handler_adapter.dart';
import 'package:engirdle_mobile/shared_kernel/content_identity.dart';
import 'package:flutter_test/flutter_test.dart';

/// The system-media projection must expose only safe metadata and only the
/// MVP-supported play/pause/stop actions (design §3.2, §5.3, §9.1).
void main() {
  final ref = ArticleRef(articleId: 'a1', revision: 1, artifactRevision: 1);

  PlaybackSnapshot snapshot({
    PlaybackPhase phase = PlaybackPhase.playing,
    PlaybackMode mode = PlaybackMode.continuous,
    String title = 'An Article',
    String? author = 'An Author',
    String currentLabel = '第 1 段第 1 句',
    int ordinal = 1,
  }) =>
      PlaybackSnapshot(
        sessionToken: 1,
        articleRef: ref,
        title: title,
        author: author,
        mode: mode,
        phase: phase,
        currentSentenceId: 's1',
        currentLabel: currentLabel,
        sentenceOrdinal: ordinal,
        position: const Duration(milliseconds: 500),
        playableDuration: const Duration(seconds: 30),
      );

  group('mediaItemFromSnapshot', () {
    test('id is a logical article id, never a file path', () {
      final item = mediaItemFromSnapshot(snapshot());
      expect(item.id, 'engirdle:article:a1');
      expect(item.id.contains('/'), isFalse);
      expect(item.id.contains('.m4a'), isFalse);
    });

    test('exposes title/author/album and mode subtitle only', () {
      final item = mediaItemFromSnapshot(snapshot());
      expect(item.title, 'An Article');
      expect(item.artist, 'An Author');
      expect(item.album, 'Engirdle');
      expect(item.displaySubtitle, '连续 · 当前第 1 段第 1 句');
    });

    test('never carries body/translation/path/lan in extras', () {
      final item = mediaItemFromSnapshot(
        snapshot(mode: PlaybackMode.sentence, title: '/secret/path/body text'),
      );
      expect(item.extras, isNull);
      // Even a pathological title is shown verbatim as a title (display), never
      // leaked as a path field — there is no path/lane/body field on MediaItem.
      expect(item.id.contains('secret'), isFalse);
    });

    test('idle snapshot yields an empty placeholder item', () {
      final item = mediaItemFromSnapshot(const PlaybackSnapshot.idle());
      expect(item.id, 'engirdle:none');
      expect(item.title, '');
    });
  });

  group('playbackStateFromSnapshot', () {
    test('playing exposes pause + stop, ready state', () {
      final state = playbackStateFromSnapshot(snapshot(phase: PlaybackPhase.playing));
      expect(state.playing, isTrue);
      expect(state.processingState, AudioProcessingState.ready);
      expect(
        state.controls.map((c) => c.action),
        containsAll([MediaAction.pause, MediaAction.stop]),
      );
    });

    test('paused exposes play + stop', () {
      final state = playbackStateFromSnapshot(snapshot(phase: PlaybackPhase.paused));
      expect(state.playing, isFalse);
      expect(
        state.controls.map((c) => c.action),
        containsAll([MediaAction.play, MediaAction.stop]),
      );
    });

    test('declares only play/pause/stop as system actions', () {
      final state = playbackStateFromSnapshot(snapshot());
      expect(state.systemActions, {MediaAction.play, MediaAction.pause, MediaAction.stop});
    });

    test('idle yields the idle processing state and no controls', () {
      final state =
          playbackStateFromSnapshot(const PlaybackSnapshot.idle());
      expect(state.processingState, AudioProcessingState.idle);
      expect(state.controls, isEmpty);
    });
  });
}
