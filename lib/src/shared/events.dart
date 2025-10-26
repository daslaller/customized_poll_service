// events.dart
import 'dart:core';
typedef OnPollAction<T> = Future<T> Function();

enum PollEventType {
  success,
  error,
  started,
  stopped,
  paused,
  resumed,
  reset,
  disposed,
  intervalChanged,
}

enum PollStatus { running, paused, stopped }

class PollError {
  final Object error;
  final StackTrace stackTrace;
  final DateTime timestamp;

  PollError(this.error, this.stackTrace, this.timestamp);

  @override
  String toString() => 'PollError($error at $timestamp)';
}

class PollEvent<T> {
  final PollEventType type;
  final T? data;
  final int successfulPollCount;
  final DateTime timestamp;
  final String identifier;
  final PollStatus status;
  final Duration? duration;
  final PollError? error;
  final Map<String, dynamic>? metadata;

  const PollEvent({
    required this.type,
    this.data,
    required this.successfulPollCount,
    required this.timestamp,
    required this.identifier,
    required this.status,
    this.duration,
    this.error,
    this.metadata,
  });

  @override
  String toString() =>
      'PollEvent($type, pollCount: $successfulPollCount, data: $data)';
}

// a - (a / b.abs()).floor() * b.abs() modulo
Duration durationModulo({required Duration a, required Duration b}) {
  Duration q = a ~/ b.inMicroseconds;
  return a - (q * b.abs().inMicroseconds);
}
