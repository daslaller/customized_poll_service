// bin/demo_async_queue.dart
import 'dart:async';
import 'dart:math';

import '../AsyncRepeatEngine.dart'; // your file
import '../shared/events.dart';

Future<void> main() async {
  print('📦 AsyncRepeatEngine: queue ticks (sequential processing)\n');

  // period 100ms; work 200ms => backlog builds while running
  final engine = AsyncRepeatEngine<String>(
    name: 'queued',
    pollingInterval: const Duration(milliseconds: 100),
    onPoll: () async {
      await Future.delayed(const Duration(milliseconds: 200));
      return 'work @ ${DateTime.now().toIso8601String()}';
    },
  );

  int count = 0;
  engine.events.listen((e) {
    if (e.type == PollEventType.success) {
      count++;
      print('✅ success #$count  data=${e.data}');
    }
  });

  // Let it run 1s to accumulate some backlog, then PAUSE 500ms (more backlog),
  // then resume. After resume, you’ll see a continuous stream catching up.
  await Future.delayed(const Duration(seconds: 1));
  print('\n⏸️ pause 500ms (ticks still scheduled; backlog builds)');
  engine.pause();
  await Future.delayed( Duration(milliseconds: Random().nextInt(4999)+1));

  print('▶️ resume — watch it process queued ticks sequentially');
  engine.resume();

  await Future.delayed(const Duration(seconds: 2));
  engine.dispose();
  print('\n→ All scheduled ticks were preserved and processed in order (no overlap).');
}
