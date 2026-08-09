import 'dart:async';

import 'package:audio_session/audio_session.dart';

import '../application/audio_focus_port.dart';

/// Maps `audio_session`'s interruption / becoming-noisy / output-route signals
/// into [AudioFocusEvent]s for the coordinator (design §6.2). The global
/// session is configured for speech/audiobook; focus *activation* itself stays
/// with just_audio's auto audio-session activation, while *release* is explicit:
/// the coordinator calls [releaseFocus] when a session ends (design §3.1).
/// This adapter only surfaces the events the coordinator must react to. No
/// policy lives here — it is a pure translator, not a second state machine.
class AudioSessionAdapter implements AudioFocusPort {
  AudioSessionAdapter._(this._session);

  final AudioSession _session;
  final _events = StreamController<AudioFocusEvent>.broadcast();
  late final StreamSubscription<AudioInterruptionEvent> _interruption;
  late final StreamSubscription<void> _noisy;
  late final StreamSubscription<AudioDevicesChangedEvent> _devices;

  /// Configures the global audio session for spoken audio and returns an
  /// adapter over it. Call once at startup, after the audio plugins load and
  /// before any playback (design §7.1).
  static Future<AudioSessionAdapter> init() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    final adapter = AudioSessionAdapter._(session);
    adapter._wire();
    return adapter;
  }

  void _wire() {
    _interruption = _session.interruptionEventStream.listen((event) {
      final mapped = mapInterruption(event);
      if (mapped != null) _events.add(mapped);
    });
    _noisy = _session.becomingNoisyEventStream.listen(
      (_) => _events.add(BecomingNoisy()),
    );
    _devices = _session.devicesChangedEventStream.listen((event) {
      // An active output (e.g. Bluetooth A2DP) going away should pause and not
      // auto-resume — same policy as becoming-noisy (design §3.1).
      if (event.devicesRemoved.any((d) => d.isOutput)) {
        _events.add(OutputDisconnected());
      }
    });
  }

  /// Pure mapping (unit-tested directly): an `AudioInterruptionEvent` becomes
  /// a domain [AudioFocusEvent]. `begin=false` is focus regained; `unknown`
  /// (Android permanent focus loss) is non-recoverable; `pause`/`duck` are
  /// transient.
  static AudioFocusEvent? mapInterruption(AudioInterruptionEvent event) {
    if (!event.begin) return FocusRegained();
    switch (event.type) {
      case AudioInterruptionType.unknown:
        return PermanentFocusLoss();
      case AudioInterruptionType.pause:
      case AudioInterruptionType.duck:
        return TransientFocusLoss();
    }
  }

  @override
  Stream<AudioFocusEvent> get events => _events.stream;

  @override
  Future<void> releaseFocus() => _session.setActive(false);

  Future<void> dispose() async {
    await releaseFocus();
    await _interruption.cancel();
    await _noisy.cancel();
    await _devices.cancel();
    await _events.close();
  }
}
