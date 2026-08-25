import 'dart:async';

import 'package:engirdle_mobile/features/translation/infrastructure/in_process_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runs scheduled jobs serially through the bound runner', () async {
    final scheduler = InProcessTranslationScheduler();
    final ran = <String>[];
    final firstGate = Completer<void>();
    var running = false;
    scheduler.runner = (jobId) async {
      expect(running, isFalse, reason: 'jobs must not overlap');
      running = true;
      if (jobId == 'j1') await firstGate.future;
      ran.add(jobId);
      running = false;
      return null;
    };
    scheduler.schedule('j1');
    scheduler.schedule('j2');
    await Future<void>.delayed(Duration.zero);
    // j1 blocks on its gate; j2 stays queued behind it (§8.4 one job at a
    // time).
    expect(ran, isEmpty);
    firstGate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(ran, ['j1', 'j2']);
  });

  test('a delayed schedule runs only after the delay', () async {
    final scheduler = InProcessTranslationScheduler();
    final ran = <String>[];
    scheduler.runner = (jobId) async {
      ran.add(jobId);
      return null;
    };
    scheduler.schedule('j1', after: const Duration(milliseconds: 30));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(ran, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(ran, ['j1']);
  });

  test('a second delayed request while one is pending is a no-op', () async {
    final scheduler = InProcessTranslationScheduler();
    final ran = <String>[];
    scheduler.runner = (jobId) async {
      ran.add(jobId);
      return null;
    };
    scheduler.schedule('j1', after: const Duration(milliseconds: 20));
    scheduler.schedule('j1', after: const Duration(milliseconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(ran, ['j1']);
  });

  test('cancelScheduled drops queued and delayed executions', () async {
    final scheduler = InProcessTranslationScheduler();
    final ran = <String>[];
    final gate = Completer<void>();
    scheduler.runner = (jobId) async {
      if (jobId == 'j1') await gate.future;
      ran.add(jobId);
      return null;
    };
    scheduler.schedule('j1');
    scheduler.schedule('j2'); // queued behind the blocked j1
    scheduler.schedule('j3', after: const Duration(milliseconds: 20));
    scheduler.cancelScheduled('j2');
    scheduler.cancelScheduled('j3');
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(ran, ['j1']);
  });
}
