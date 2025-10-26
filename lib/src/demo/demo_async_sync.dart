// bin/demo_async_sync.dart
import 'dart:async';

import '../SyncRepeatEngine.dart'; // your file

Future<void> main() async {
  print('🔁 AsyncSyncResultRepeatEngine: drop ticks while busy\n');

  // onPoll takes ~250ms; period is 100ms → many ticks arrive while busy
  final engine = AsyncSyncResultRepeatEngine<String>(
    name: 'sync-result',
    pollingInterval: const Duration(milliseconds: 100),
    onPoll: () async {
      final t0 = DateTime.now();
      await Future.delayed(const Duration(milliseconds: 250));
      return 'done @ ${t0.toIso8601String()}';
    },
  );

  // Count theoretical ticks (what *would* have happened)
  int scheduledTicks = 0;
  final tickCounter = Timer.periodic(const Duration(milliseconds: 100), (_) { scheduledTicks++; });

  int successes = 0;
  final sub = engine.events.listen((e) {
    if (e.type == PollEventType.success) {
      successes++;
      print('✅ success #$successes  (duration ~${e.duration?.inMilliseconds}ms)  data=${e.data}');
    }
  });

  // Let it run for a short time then stop
  await Future.delayed(const Duration(seconds: 3));
  engine.dispose();
  tickCounter.cancel();
  await sub.cancel();

  print('\nScheduled ticks (theoretical): $scheduledTicks');
  print('Observed successes (actual):   $successes');
  print('→ Because onPoll > period, extra ticks were DROPPED (exhaust behavior).\n');
}
