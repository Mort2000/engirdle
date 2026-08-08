import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/playback_models.dart';
import 'playback_engine.dart';

/// Owns the single playback session (MOB-AUD-003/004, design §8.4).
///
/// Every new play command cancels the old clip and pending callbacks before
/// issuing a new one; completion events are validated against the session
/// token so stale async events can never stop a newer session.
///
/// Token protocol: `_token` identifies the latest command, `_settledToken`
/// the latest command whose engine call has already returned. The engine
/// futures complete once playback *starts* (just_audio's play() resolves
/// when the platform acknowledges the play request, not at clip end), so a
/// completion event arriving while `_settledToken != _token` can only belong
/// to the superseded clip and must be ignored.
class PlaybackController {
  PlaybackController({required PlaybackEngine engine}) : _engine = engine {
    _positionSub = _engine.positionStream.listen(_onPosition);
    _completionSub = _engine.completionStream.listen((_) => _onCompleted());
  }

  final PlaybackEngine _engine;

  final ValueNotifier<PlaybackViewState> state = ValueNotifier(
    const PlaybackViewState.idle(),
  );

  final _events = StreamController<PlaybackEvent>.broadcast();
  Stream<PlaybackEvent> get events => _events.stream;

  late final StreamSubscription<Duration> _positionSub;
  late final StreamSubscription<void> _completionSub;

  String? _filePath;
  List<SentenceAudioRange> _ranges = const [];
  int _token = 0;

  /// Latest command whose engine await has returned (see class doc).
  int _settledToken = 0;

  /// Attaches an article's audio timeline. Must be called before playing;
  /// re-attaching the same file is cheap.
  void attachArticle(String audioFilePath, List<SentenceAudioRange> ranges) {
    _filePath = audioFilePath;
    _ranges = ranges;
  }

  SentenceAudioRange? _rangeOf(String sentenceId) {
    for (final range in _ranges) {
      if (range.sentenceId == sentenceId) return range;
    }
    return null;
  }

  /// Sentence mode: play `[start_ms, end_ms)` and stop at the boundary
  /// (MOB-AUD-001).
  Future<void> playSentence(String sentenceId) async {
    final filePath = _filePath;
    final range = _rangeOf(sentenceId);
    if (filePath == null || range == null) return;
    _beginCommand();
    final token = _token;
    state.value = PlaybackViewState(
      status: PlaybackStatus.playing,
      mode: PlaybackMode.sentence,
      currentSentenceId: range.sentenceId,
      currentLabel: range.label,
      position: Duration.zero,
      clipLength: range.end - range.start,
    );
    try {
      await _engine.playClip(
        filePath: filePath,
        start: range.start,
        end: range.end,
      );
      if (token == _token) _settledToken = token;
    } catch (_) {
      // Callers fire-and-forget (sheet callbacks are not awaited), so the
      // error must not escape; a superseded command's failure is expected
      // noise from the replaced session and is dropped silently.
      if (token == _token) {
        state.value = const PlaybackViewState.idle();
        unawaited(_engine.stop());
      }
    }
  }

  /// Continuous mode: clear the end clip and play from the target sentence
  /// to the end of the article (MOB-AUD-002). A paragraph start resolves to
  /// its first sentence — callers pass the block's first sentence id.
  Future<void> playContinuousFrom(String sentenceId) async {
    final filePath = _filePath;
    final range = _rangeOf(sentenceId);
    if (filePath == null || range == null) return;
    _beginCommand();
    final token = _token;
    state.value = PlaybackViewState(
      status: PlaybackStatus.playing,
      mode: PlaybackMode.continuous,
      currentSentenceId: range.sentenceId,
      currentLabel: range.label,
      position: Duration.zero,
      startLabel: range.label,
    );
    try {
      await _engine.playFrom(filePath: filePath, start: range.start);
      if (token == _token) _settledToken = token;
    } catch (_) {
      // Same contract as playSentence: never rethrow, only the live command
      // resets the session on failure.
      if (token == _token) {
        state.value = const PlaybackViewState.idle();
        unawaited(_engine.stop());
      }
    }
  }

  Future<void> pause() async {
    if (state.value.status != PlaybackStatus.playing) return;
    final token = _token;
    await _engine.pause();
    // Re-validate after the await: stop() or a new play command may have
    // superseded this session meanwhile — writing paused onto an idle
    // session would resurrect a zombie control bar.
    if (token != _token || state.value.status != PlaybackStatus.playing) {
      return;
    }
    state.value = state.value.copyWith(status: PlaybackStatus.paused);
  }

  Future<void> resume() async {
    if (state.value.status != PlaybackStatus.paused) return;
    final token = _token;
    await _engine.resume();
    // Same re-validation as pause().
    if (token != _token || state.value.status != PlaybackStatus.paused) {
      return;
    }
    state.value = state.value.copyWith(status: PlaybackStatus.playing);
  }

  /// Stops and collapses the control bar; state returns to Idle.
  Future<void> stop() async {
    final token = ++_token;
    await _engine.stop();
    // A play command issued during the await owns the session now; writing
    // idle here would kill it.
    if (token == _token) state.value = const PlaybackViewState.idle();
  }

  Future<void> dispose() async {
    await _positionSub.cancel();
    await _completionSub.cancel();
    await _engine.dispose();
    await _events.close();
    state.dispose();
  }

  /// A new command supersedes the old session (MOB-AUD-004).
  void _beginCommand() {
    final replacedContinuous =
        state.value.isActive && state.value.mode == PlaybackMode.continuous;
    _token++;
    if (replacedContinuous) {
      _events.add(ContinuousSessionReplaced());
    }
  }

  void _onPosition(Duration position) {
    final current = state.value;
    if (!current.isActive) return;
    if (current.mode == PlaybackMode.continuous) {
      // Track the sounding sentence for the highlight and control bar.
      final ms = position.inMilliseconds;
      SentenceAudioRange? match;
      for (final range in _ranges) {
        if (ms >= range.startMs) match = range;
        if (ms < range.endMs) break;
      }
      if (match != null && match.sentenceId != current.currentSentenceId) {
        state.value = current.copyWith(
          position: position,
          currentSentenceId: match.sentenceId,
          currentLabel: match.label,
        );
        return;
      }
    }
    state.value = current.copyWith(position: position);
  }

  void _onCompleted() {
    // Only the settled session may complete: while a newer command is still
    // inside its engine await, a completion event can only come from the
    // replaced clip reaching its natural end and must not idle the new
    // session (the state check alone cannot tell the two sessions apart).
    if (!state.value.isActive || _settledToken != _token) return;
    state.value = const PlaybackViewState.idle();
  }
}
