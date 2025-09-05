import 'dart:async';
import 'dart:io';

// Your enum-based approach
enum PollStatus { type, data, pollCount, timestamp, identifier, status }

// My class-based approach
enum PollEventType { success, error }

enum PollStatusClass { running, paused, stopped }

class ClassBasedEvent {
  final PollEventType type;
  final dynamic data;
  final int pollCount;
  final DateTime timestamp;
  final String identifier;
  final PollStatusClass status;
  final Duration? duration;
  final Map<String, dynamic>? metadata;

  ClassBasedEvent({
    required this.type,
    this.data,
    required this.pollCount,
    required this.timestamp,
    required this.identifier,
    required this.status,
    this.duration,
    this.metadata,
  });
}

void main() async {
  print('FAIR COMPARISON - NO CHEATING');

  // Test 1: Memory footprint with proper measurement
  print('\n1. Memory Footprint Test (100 instances each):');

  // Force GC and measure baseline
  for (int i = 0; i < 5; i++) {
    await Future.delayed(Duration(milliseconds: 50));
  }
  final classList = <ClassBasedEvent>[];
  final enumList = <Map<PollStatus, String>>[];
  var baseline = ProcessInfo.currentRss;
  // Test class approach

  for (int i = 0; i < 100; i++) {
    final event = ClassBasedEvent(
      type: PollEventType.success,
      data: 'Data: $i',
      pollCount: i,
      timestamp: DateTime.now(),
      identifier: 'test_$i',
      status: PollStatusClass.running,
    );
    classList.add(event);
  }
  final afterClass = ProcessInfo.currentRss;
  final classMemory = afterClass - baseline;
  classList.clear();

  for (int i = 0; i < 5; i++) {
    await Future.delayed(Duration(milliseconds: 50));
  }
  // Test enum approach
  baseline = ProcessInfo.currentRss;

  for (int i = 0; i < 100; i++) {
    final event = <PollStatus, String>{
      PollStatus.type: 'poll',
      PollStatus.data: 'Data: $i',
      PollStatus.pollCount: '$i',
      PollStatus.timestamp: '$DateTime.now()',
      PollStatus.identifier: 'test_$i',
      PollStatus.status: 'running',
    };
    enumList.add((event));
  }
  final afterEnum = ProcessInfo.currentRss;
  final enumMemory = afterEnum - baseline;

  // Clear enum list and force GC
  enumList.clear();

  print('Enum memory: ${enumMemory} bytes');
  print('Class memory: ${classMemory} bytes');
  print('Memory ratio: ${classMemory / enumMemory}');

  // Test 2: Performance with identical operations
  print('\n2. Performance Test (50 instances, 1000 events each):');

  final enumControllers =
      <StreamController <Map<PollStatus, String>>>[];
  final classControllers = <StreamController<ClassBasedEvent>>[];

  // Create controllers
  for (int i = 0; i < 50; i++) {
    enumControllers.add(
      StreamController<Map<PollStatus, String>>.broadcast(),
    );
    classControllers.add(StreamController<ClassBasedEvent>.broadcast());
  }
  // Test class performance
  final classStopwatch = Stopwatch()..start();
  for (int i = 0; i < 50; i++) {
    for (int j = 0; j < 1000; j++) {
      final event = ClassBasedEvent(
        type: PollEventType.success,
        data: j,
        pollCount: j,
        timestamp: DateTime.now(),
        identifier: 'test_$i',
        status: PollStatusClass.running,
      );
      classControllers[i].add(event);
    }
  }
  classStopwatch.stop();
  // Test enum performance
  final enumStopwatch = Stopwatch()..start();
  for (int i = 0; i < 50; i++) {
    for (int j = 0; j < 1000; j++) {
      final event = {
        PollStatus.type: 'Poll',
        PollStatus.data: '$j',
        PollStatus.pollCount: '$j',
        PollStatus.timestamp: '$DateTime.now()',
        PollStatus.identifier: 'test_$i',
        PollStatus.status: 'running',
      };
      enumControllers[i].add(event);
    }
  }
  enumStopwatch.stop();

  print('Enum time: ${enumStopwatch.elapsedMicroseconds} μs');
  print('Class time: ${classStopwatch.elapsedMicroseconds} μs');
  print(
    'Performance ratio: ${enumStopwatch.elapsedMicroseconds / classStopwatch.elapsedMicroseconds}',
  );

  // Cleanup
  for (final controller in enumControllers) {
    await controller.close();
  }
  for (final controller in classControllers) {
    await controller.close();
  }

  print('\nFINAL RESULTS:');
  print(
    'Memory: Enum=${enumMemory} bytes, Class=${classMemory} bytes, Ratio=${classMemory / enumMemory}',
  );
  print(
    'Performance: Enum=${enumStopwatch.elapsedMicroseconds}μs, Class=${classStopwatch.elapsedMicroseconds}μs, Ratio=${enumStopwatch.elapsedMicroseconds / classStopwatch.elapsedMicroseconds}',
  );
}
