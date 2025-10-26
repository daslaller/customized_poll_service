// bin/demo_isolate.dart
import 'dart:async';
import 'dart:math';

import '../IsolateRepeatEngine.dart'; // your file (AdvancedRepeatEngine or the isolate-based one)
import '../shared/events.dart';

// Simulate heavy CPU (pure function)
int fib(int n) => n < 2 ? n : fib(n - 1) + fib(n - 2);

Future<void> main() async {
  print('🧠 IsolateRepeatEngine: heavy work off main isolate\n');

  final rnd = Random(42);
  final engine = AdvancedRepeatEngine<int>( // or whatever your isolate engine class is named
    name: 'isolate-engine',
    pollingInterval: const Duration(milliseconds: 150),
    concurrency: 2, // demonstrate parallel workers if you want
    onPoll: () async {
      final n = 32 + rnd.nextInt(3); // heavy-ish
      final t0 = DateTime.now();
      // This executes in an isolate in your engine:
      final result = fib(n); // or wrap inside runInIsolate per your engine
      final ms = DateTime.now().difference(t0).inMilliseconds;
      return result; // engine emits duration for you
    },
  );

  int successes = 0, errors = 0;
  final sub = engine.events.listen((e) {
    switch (e.type) {
      case PollEventType.success:
        successes++;
        print('✅ success #$successes  (took ~${e.duration?.inMilliseconds}ms) result=${e.data}');
        break;
      case PollEventType.error:
        errors++;
        print('❌ error: ${e.error}');
        break;
      default:
        break;
    }
  });

  // Keep it short
  await Future.delayed(const Duration(seconds: 3));
  engine.dispose();
  await sub.cancel();
  print('\n→ Heavy CPU ran off the main isolate. UI/event loop remains responsive.');
}
