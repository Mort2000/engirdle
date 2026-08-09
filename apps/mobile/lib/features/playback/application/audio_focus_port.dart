/// Domain-level audio-focus / output-route events (design §6.2). The platform
/// adapter (AudioSessionAdapter) translates native focus/becoming-noisy/route
/// signals into these; the coordinator owns the recover/pause policy so the
/// player and coordinator never each pause or auto-resume once.
sealed class AudioFocusEvent {}

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

/// Source of audio-focus and output-route events for the coordinator. Focus
/// activation itself stays with just_audio's auto audio-session activation
/// (design §6.2); this port only surfaces the events the coordinator must react to.
abstract class AudioFocusPort {
  Stream<AudioFocusEvent> get events;
}

/// Never-emitting focus port. Used when the platform audio session cannot be
/// configured at startup: the coordinator simply never reacts to interruptions,
/// and playback still works via just_audio's own session activation.
class NullAudioFocusPort implements AudioFocusPort {
  const NullAudioFocusPort();
  @override
  Stream<AudioFocusEvent> get events => const Stream<AudioFocusEvent>.empty();
}
