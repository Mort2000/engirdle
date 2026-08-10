/// Domain-level audio-focus / output-route events (design §6.2). The platform
/// adapter (AudioSessionAdapter) translates native focus/becoming-noisy/route
/// signals into these; the coordinator owns the recover/pause policy so the
/// player and coordinator never each pause or auto-resume once.
sealed class AudioFocusEvent {}

/// Strength of the Android audio-focus request made before playback.
enum AudioFocusMode { standard, exclusive }

/// A phone call, transient media takeover, etc. took focus but it may come back.
class TransientFocusLoss extends AudioFocusEvent {}

/// The transient interruption ended (focus regained).
class FocusRegained extends AudioFocusEvent {}

/// Focus lost indefinitely (e.g. another media app started). Never auto-resume.
class PermanentFocusLoss extends AudioFocusEvent {}

/// Headphones unplugged or output otherwise becoming noisy (design §3.1).
class BecomingNoisy extends AudioFocusEvent {}

/// Active output (e.g. Bluetooth A2DP) disconnected. Treated like becoming-noisy.
class OutputDisconnected extends AudioFocusEvent {}

/// Source of audio-focus operations and output-route events for the
/// coordinator. The coordinator owns both activation policy and interruption
/// reactions so focus denials never silently suppress playback.
abstract class AudioFocusPort {
  Stream<AudioFocusEvent> get events;

  /// Requests focus before playback. A false result is advisory: callers may
  /// still play according to product policy.
  Future<bool> acquireFocus(AudioFocusMode mode);

  /// Releases the audio focus held by the active session. The coordinator
  /// calls this on every transition to Idle (user stop, natural completion,
  /// unrecoverable error — design §3.1). Pausing keeps focus so a transient
  /// interruption can still deliver its regain event (design §6.2).
  Future<void> releaseFocus();
}

/// Never-emitting focus port. Used when the platform audio session cannot be
/// configured at startup: focus acquisition reports false, interruption events
/// remain unavailable, and best-effort playback still proceeds.
class NullAudioFocusPort implements AudioFocusPort {
  const NullAudioFocusPort();
  @override
  Stream<AudioFocusEvent> get events => const Stream<AudioFocusEvent>.empty();
  @override
  Future<bool> acquireFocus(AudioFocusMode mode) async => false;
  @override
  Future<void> releaseFocus() async {}
}
