import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../platform/logging/app_logger.dart';
import '../domain/playback_models.dart';
import '../domain/playback_source_port.dart';
import 'audio_focus_port.dart';
import 'playback_driver.dart';
import 'playback_settings_port.dart';

/// Owns the single playback session — the deep module's coordinator and the
/// only state machine (design §4.2/§5.2). Reader, in-app bar and system-media
/// commands all enter here; UI and system media both consume [state].
///
/// Token protocol: `_token` identifies the latest command, `_settledToken` the
/// latest command whose driver call has already returned. The driver's play
/// futures resolve once the request is *issued* (see [PlaybackDriver]), so a
/// completion/error event arriving while `_settledToken != _token` can only
/// belong to the superseded clip and must be ignored. Every async step
/// re-checks the token before writing state, so a stop or new start racing the
/// await can never resurrect a zombie session.
class PlaybackController {
  PlaybackController({
    required PlaybackDriver driver,
    required PlaybackSourcePort sourcePort,
    required AudioFocusPort focusPort,
    required PlaybackSettingsPort settingsPort,
    AppLogger? logger,
  }) : _driver = driver,
       _source = sourcePort,
       _focus = focusPort,
       _settings = settingsPort,
       _logger = logger ?? const AppLogger('playback') {
    _driverSub = _driver.events.listen(_onDriverEvent);
    _focusSub = _focus.events.listen(_onFocusEvent);
  }

  final PlaybackDriver _driver;
  final PlaybackSourcePort _source;
  final AudioFocusPort _focus;
  final PlaybackSettingsPort _settings;
  final AppLogger _logger;

  final ValueNotifier<PlaybackSnapshot> state = ValueNotifier(
    const PlaybackSnapshot.idle(),
  );

  final _events = StreamController<PlaybackEvent>.broadcast();
  Stream<PlaybackEvent> get events => _events.stream;

  late final StreamSubscription _driverSub;
  late final StreamSubscription _focusSub;

  PlaybackSourceLease? _lease;
  int _token = 0;

  /// Latest command whose driver await has returned (see class doc).
  int _settledToken = 0;

  /// Token of a session paused by a *transient* focus loss that may resume on
  /// regain. Voided by any user command or a non-recoverable event.
  int? _recoverableFocusToken;

  /// Starts a session from [request] (design §4.2). A new request supersedes
  /// any prior session; the prior lease stays pinned until the driver has
  /// switched to the new source, so cleanup can never delete a file the player
  /// is still reading (design §6.3).
  Future<void> start(PlaybackRequest request) async {
    _beginCommand();
    final token = _token;
    try {
      final lease = await _source.acquire(request.articleRef);
      // Superseded while acquiring: hand back the stale lease and bail. The
      // prior session's lease (if any) is owned by the superseding command.
      if (token != _token) {
        _source.release(lease);
        return;
      }
      final range = _rangeOf(lease.ranges, request.sentenceId);
      if (range == null) {
        _source.release(lease);
        _fail(token, '该句子没有音频');
        return;
      }
      await _acquireFocusBestEffort();
      if (token != _token) {
        _source.release(lease);
        return;
      }
      // Take over the session, but keep the superseded lease pinned until the
      // dispatch below returns: only then has the driver stopped reading the
      // old file (its setAudioSource/seek awaits are inside _dispatchPlay).
      final superseded = _lease;
      _lease = lease;
      state.value = _initialSnapshot(token, lease, request, range);
      try {
        await _dispatchPlay(request, lease, range);
      } finally {
        if (superseded != null) _source.release(superseded);
      }
      if (token == _token) {
        _settledToken = token;
        state.value = state.value.copyWith(phase: PlaybackPhase.playing);
      }
    } on Object catch (error) {
      // Callers fire-and-forget (sheet callbacks are not awaited), so the error
      // must not escape; a superseded command's failure is expected noise from
      // the replaced session and is dropped silently.
      if (token == _token) {
        _logger.error('playback.start_failed', {'error': '$error'});
        _fail(token, '无法开始播放');
      }
    }
  }

  Future<void> pause() async {
    // Any explicit pause voids a pending transient-loss recovery, then this is
    // a non-recoverable system pause.
    _recoverableFocusToken = null;
    await _systemPause(recoverable: false);
  }

  Future<void> resume() async {
    // Any explicit resume takes over; do not later auto-resume on focus regain.
    _recoverableFocusToken = null;
    if (state.value.phase != PlaybackPhase.paused) return;
    final token = _token;
    await _acquireFocusBestEffort();
    if (token != _token || state.value.phase != PlaybackPhase.paused) return;
    await _driver.resume();
    if (token != _token || state.value.phase != PlaybackPhase.paused) return;
    state.value = state.value.copyWith(phase: PlaybackPhase.playing);
  }

  /// Stops and collapses the bar; state returns to idle. Idempotent.
  Future<void> stop() async {
    final token = ++_token;
    _recoverableFocusToken = null;
    await _driver.stop();
    // A play command issued during the await owns the session now — including
    // the lease hand-off — so releasing or writing idle here would kill it.
    if (token != _token) return;
    // Focus and lease are released only after the driver's stop returned:
    // until then the player may still be reading the leased file.
    await _focus.releaseFocus();
    _releaseLease();
    state.value = const PlaybackSnapshot.idle();
  }

  /// Stops the active session iff it belongs to [articleId] — the prelude to a
  /// safe delete (design §6.3). No-op otherwise.
  Future<void> stopIfActive(String articleId) async {
    if (state.value.isActive &&
        state.value.articleRef?.articleId == articleId) {
      await stop();
    }
  }

  Future<void> dispose() async {
    await _driverSub.cancel();
    await _focusSub.cancel();
    await _focus.releaseFocus();
    _releaseLease();
    await _driver.dispose();
    await _events.close();
    state.dispose();
  }

  // ---- Command helpers ----

  /// A new start supersedes the old session (UX-A2 replacement notice). The
  /// old lease is NOT released here: the driver may still be reading the old
  /// file, so custody passes to the new command, which releases it once the
  /// driver has switched sources (see [start]).
  void _beginCommand() {
    final replacedContinuous =
        state.value.isActive && state.value.mode == PlaybackMode.continuous;
    _token++;
    _recoverableFocusToken = null;
    if (replacedContinuous) _events.add(ContinuousSessionReplaced());
  }

  Future<void> _dispatchPlay(
    PlaybackRequest request,
    PlaybackSourceLease lease,
    SentenceAudioRange range,
  ) {
    if (request.mode == PlaybackMode.sentence) {
      return _driver.playClip(
        filePath: lease.audioFilePath,
        start: range.start,
        end: range.end,
      );
    }
    return _driver.playFrom(filePath: lease.audioFilePath, start: range.start);
  }

  void _fail(int token, String reason) {
    if (token != _token) return;
    unawaited(_focus.releaseFocus());
    _releaseLease();
    _recoverableFocusToken = null;
    unawaited(_driver.stop());
    state.value = const PlaybackSnapshot.idle();
    _events.add(PlaybackFailed(reason));
  }

  void _releaseLease() {
    final lease = _lease;
    _lease = null;
    if (lease != null) _source.release(lease);
  }

  PlaybackSnapshot _initialSnapshot(
    int token,
    PlaybackSourceLease lease,
    PlaybackRequest request,
    SentenceAudioRange range,
  ) {
    final ordinal = lease.ranges.indexOf(range) + 1;
    return PlaybackSnapshot(
      sessionToken: token,
      articleRef: lease.articleRef,
      title: lease.title,
      author: lease.author,
      mode: request.mode,
      phase: PlaybackPhase.preparing,
      currentSentenceId: range.sentenceId,
      currentLabel: range.label,
      startLabel: request.mode == PlaybackMode.continuous ? range.label : null,
      sentenceOrdinal: ordinal,
      position: Duration.zero,
      playableDuration: request.mode == PlaybackMode.continuous
          ? lease.totalDuration
          : range.end - range.start,
    );
  }

  SentenceAudioRange? _rangeOf(List<SentenceAudioRange> ranges, String id) {
    for (final range in ranges) {
      if (range.sentenceId == id) return range;
    }
    return null;
  }

  int? _ordinalOf(String sentenceId) {
    final ranges = _lease?.ranges ?? const [];
    for (var i = 0; i < ranges.length; i++) {
      if (ranges[i].sentenceId == sentenceId) return i + 1;
    }
    return null;
  }

  // ---- Driver event reducer ----

  void _onDriverEvent(PlaybackDriverEvent event) {
    switch (event) {
      case DriverCompleted():
        // Only the settled session may complete (see class doc).
        if (!state.value.isActive || _settledToken != _token) return;
        unawaited(_focus.releaseFocus());
        _releaseLease();
        state.value = const PlaybackSnapshot.idle();
      case DriverError():
        if (!state.value.isActive || _settledToken != _token) return;
        _logger.error('playback.driver_failed', {});
        _fail(_token, '播放出错');
      case DriverPosition():
        _onPosition(event.position);
    }
  }

  void _onPosition(Duration position) {
    final current = state.value;
    if (!current.isActive) return;
    if (current.mode == PlaybackMode.continuous) {
      final match = sentenceContaining(_lease?.ranges ?? const [], position);
      if (match != null && match.sentenceId != current.currentSentenceId) {
        state.value = current.copyWith(
          position: position,
          currentSentenceId: match.sentenceId,
          currentLabel: match.label,
          sentenceOrdinal: _ordinalOf(match.sentenceId),
        );
        return;
      }
    }
    state.value = current.copyWith(position: position);
  }

  // ---- Audio-focus / route state machine (design §6.2) ----

  void _onFocusEvent(AudioFocusEvent event) {
    switch (event) {
      case TransientFocusLoss():
        _systemPause(recoverable: true);
      case FocusRegained():
        // Resume only if a recoverable loss is still in effect and no user
        // command superseded it.
        if (_recoverableFocusToken == _token &&
            state.value.phase == PlaybackPhase.paused) {
          _systemResume();
        }
      case PermanentFocusLoss():
      case BecomingNoisy():
      case OutputDisconnected():
        _recoverableFocusToken = null;
        _systemPause(recoverable: false);
    }
  }

  Future<void> _systemPause({required bool recoverable}) async {
    if (state.value.phase != PlaybackPhase.playing) return;
    final token = _token;
    await _driver.pause();
    if (token != _token || state.value.phase != PlaybackPhase.playing) return;
    state.value = state.value.copyWith(phase: PlaybackPhase.paused);
    if (recoverable) _recoverableFocusToken = token;
  }

  Future<void> _systemResume() async {
    if (state.value.phase != PlaybackPhase.paused) return;
    final token = _token;
    await _acquireFocusBestEffort();
    if (token != _token || state.value.phase != PlaybackPhase.paused) return;
    await _driver.resume();
    if (token != _token || state.value.phase != PlaybackPhase.paused) return;
    _recoverableFocusToken = null;
    state.value = state.value.copyWith(phase: PlaybackPhase.playing);
  }

  Future<void> _acquireFocusBestEffort() async {
    final mode = _settings.interruptBackgroundAudio
        ? AudioFocusMode.exclusive
        : AudioFocusMode.standard;
    try {
      final acquired = await _focus.acquireFocus(mode);
      if (!acquired) {
        _logger.warn('playback.audio_focus_denied', {'mode': mode.name});
      }
    } on Object catch (error) {
      _logger.warn('playback.audio_focus_failed', {
        'mode': mode.name,
        'error': '$error',
      });
    }
  }
}
