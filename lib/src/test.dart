

import 'dart:io';
import 'dart:math';
import '../customized_poll_service.dart';

void main() async {
  print('🚀 Enhanced RepeatEngine Demo\n');
  
  // Create a type-safe polling service
  final pollService = RepeatEngine<String>(
    name: 'DemoService',
    onPoll: () => data('test'),
    pollingInterval: const Duration(seconds: 1),
    runUntilDisposed: true,
    enableErrorRecovery: true,
    maxRetries: 3,
  );
  
  // Listen to all events including lifecycle events
  pollService.events.listen((event) {
    print('Raw event: $event');
    switch (event.type) {
      case PollEventType.success:
        print('✅ Poll #${event.successfulPollCount}: ${event.data}');
        break;
      case PollEventType.error:
        print('❌ Error: ${event.error?.error}');
        break;
      case PollEventType.started:
        print('🚀 Service started (interval: ${event.metadata?['pollingInterval']}ms)');
        break;
      case PollEventType.stopped:
        print('⏹️ Service stopped');
        break;
      case PollEventType.paused:
        print('⏸️ Service paused at ${event.metadata?['pauseStartTime']}');
        break;
      case PollEventType.resumed:
        print('▶️ Service resumed (paused for ${event.metadata?['pauseDuration']}ms)');
        break;
      case PollEventType.reset:
        print('🔄 Service reset (was running for ${event.metadata?['oldUptime']}s)');
        break;
      case PollEventType.intervalChanged:
        print('⚙️ Interval changed: ${event.metadata?['oldInterval']}ms → ${event.metadata?['newInterval']}ms');
        break;
      case PollEventType.disposed:
        print('💀 Service disposed');
        break;
    }
  });
  
  print('Poll service started. Press Ctrl+C to stop.\n');
  
  // Demo lifecycle events after a few polls
  await Future.delayed(Duration(seconds: 3));
  
  print('\n--- Demo: Pausing for 2 seconds ---');
  pollService.pause();
  await Future.delayed(Duration(seconds: 2));
  
  print('--- Demo: Resuming ---');
  pollService.resume();
  await Future.delayed(Duration(seconds: 2));
  
  print('--- Demo: Changing interval ---');
  pollService.updatePollingInterval(Duration(milliseconds: 500));
  await Future.delayed(Duration(seconds: 2));
  
  print('--- Demo: Resetting ---');
  pollService.reset();
  await Future.delayed(Duration(seconds: 2));
  
  // Set up graceful shutdown
  ProcessSignal.sigint.watch().listen((_) {
    print('\n🛑 Shutting down gracefully...');
    pollService.dispose();
    exit(0);
  });
  
  // Wait until disposed
  await pollService.keepAlive;
  print('Program finished');
}

// Simulate data fetching with occasional errors
Future<String> fetchData() async {
  await Future.delayed(Duration(milliseconds: 100));
  
  // Simulate occasional errors
  if (DateTime.now().millisecondsSinceEpoch % 7 == 0) {
    throw Exception('Simulated network error');
  }
  
  return 'Data: ${DateTime.now().millisecondsSinceEpoch}';
}

Future<String> data(String event) async {
  await Future.delayed(Duration(milliseconds: Random().nextInt(5000)));
  
  return 'Data: $event ${DateTime.now().millisecondsSinceEpoch}';
}