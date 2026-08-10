import 'package:audio_session/audio_session.dart';
import 'package:engirdle_mobile/features/playback/application/audio_focus_port.dart';
import 'package:engirdle_mobile/features/playback/infrastructure/audio_session_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure interruption mapping (design §6.2): how native audio_session signals
/// become domain AudioFocusEvents the coordinator reacts to.
void main() {
  test('exclusive focus uses Android transient-exclusive gain', () {
    expect(
      AudioSessionAdapter.mapFocusMode(AudioFocusMode.exclusive),
      AndroidAudioFocusGainType.gainTransientExclusive,
    );
  });

  test('standard focus uses Android long-lived gain', () {
    expect(
      AudioSessionAdapter.mapFocusMode(AudioFocusMode.standard),
      AndroidAudioFocusGainType.gain,
    );
  });

  group('mapInterruption', () {
    test('begin + pause is a transient loss', () {
      expect(
        AudioSessionAdapter.mapInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        ),
        isA<TransientFocusLoss>(),
      );
    });

    test('begin + duck is a transient loss', () {
      expect(
        AudioSessionAdapter.mapInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.duck),
        ),
        isA<TransientFocusLoss>(),
      );
    });

    test('begin + unknown (permanent focus loss) is non-recoverable', () {
      expect(
        AudioSessionAdapter.mapInterruption(
          AudioInterruptionEvent(true, AudioInterruptionType.unknown),
        ),
        isA<PermanentFocusLoss>(),
      );
    });

    test('end (begin=false) is focus regained', () {
      expect(
        AudioSessionAdapter.mapInterruption(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        ),
        isA<FocusRegained>(),
      );
    });
  });
}
