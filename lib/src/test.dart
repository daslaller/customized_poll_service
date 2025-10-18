// demo/main.dart
import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../customized_poll_service.dart'; // <- your RepeatEngine<T> file

Future<void> main() async {
  print('🚀 RepeatEngine Demo (queue + workers)\n');

  // Create a poll service (tweak overflow/queue to taste)
  final pollService = RepeatEngine<String>(
    name: 'DemoService',
    onPoll: () => data('test'),
    pollingInterval: const Duration(seconds: 1),
// framebuffer-ish behavior
  );

  // Consume data results with await-for (non-blocking)
  unawaited(() async {
    await for (final value in pollService.successStream) {
      print('📥 dataStream: $value');
    }
  }());

  // Listen to all events (including lifecycle)
  pollService.events.listen((event) {
    switch (event.type) {
      case PollEventType.success:
        print('✅ Poll #${event.successfulPollCount} '
            '(${event.duration?.inMilliseconds} ms): ${event.data}');
        break;
      case PollEventType.error:
        print('❌ Error: ${event.error?.error}');
        break;
      case PollEventType.started:
        print('🚀 Service started '
            '(interval: ${event.metadata?['pollingIntervalMs']} ms, '
            'concurrency: ${event.metadata?['concurrency']}, '
            'overflow: ${event.metadata?['overflow']}, '
            'queueCapacity: ${event.metadata?['queueCapacity']})');
        break;
      case PollEventType.stopped:
        print('⏹️ Service stopped');
        break;
      case PollEventType.paused:
        print('⏸️ Service paused at ${event.metadata?['pauseStartTime']}');
        break;
      case PollEventType.resumed:
        print('▶️ Service resumed '
            '(paused for ${event.metadata?['pauseDurationMs']} ms, '
            'totalPaused: ${event.metadata?['totalPauseDurationMs']} ms)');
        break;
      case PollEventType.intervalChanged:
        print('⚙️ Interval changed: '
            '${event.metadata?['oldIntervalMs']} ms → ${event.metadata?['newIntervalMs']} ms');
        break;
      case PollEventType.reset:
      // Not emitted by current engine; kept for forward-compat
        print('🔄 Service reset');
        break;
      case PollEventType.disposed:
        print('💀 Service disposed (final stats in metadata? ${event.metadata != null})');
        break;
    }
  });

  print('Poll service running. Press Ctrl+C to stop.\n');

  // Demo a few lifecycle actions
  await Future.delayed(const Duration(seconds: 3));

  print('\n--- Demo: Pausing for 2 seconds ---');
  pollService.pause();
  await Future.delayed(const Duration(seconds: 2));

  print('--- Demo: Resuming ---');
  pollService.resume();
  await Future.delayed(const Duration(seconds: 2));

  print('--- Demo: Changing interval to 500 ms ---');
  pollService.updatePollingInterval(const Duration(milliseconds: 500));
  await Future.delayed(const Duration(seconds: 2));

  // Graceful shutdown on Ctrl+C
  final done = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) {
    print('\n🛑 Shutting down gracefully...');
    pollService.dispose();
    if (!done.isCompleted) done.complete();
  });

  // Keep process alive until SIGINT
  await done.future;
  print('Program finished');
}

// Simulate work: random latency, occasional failure
Future<String> data(String tag) async {
  // Random latency up to 500 ms (use larger to see queueing/concurrency)
  await Future.delayed(Duration(milliseconds: Random().nextInt(500)));

  // Simulate ~1/7 failures
  if (DateTime.now().millisecondsSinceEpoch % 7 == 0) {
    throw Exception('Simulated error');
  }
  return 'Data[$tag] @ ${DateTime.now().millisecondsSinceEpoch}';
}
