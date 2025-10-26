import 'dart:async';
import 'dart:developer';

import 'package:customized_poll_service/src/shared/events.dart';


class AsyncSyncResultRepeatEngine<T> {
  // Config
  final String name;
  final OnPollAction<T> onPoll;
  Duration pollingInterval;
  final bool enableErrorRecovery;
  final int? maxRetries;

  // Events
  final _events = StreamController<PollEvent<T>>.broadcast();
  Stream<PollEvent<T>> get events => _events.stream;
  Stream<T> get dataStream =>
      _events.stream.where((e) => e.type == PollEventType.success && e.data != null).map((e) => e.data as T);

  // State
  bool _disposed = false;
  bool _paused = false;
  bool _inFlight = false;
  int _consecutiveErrors = 0;

  int pollCount = 0;
  DateTime? lastPollTime;
  DateTime? startTime;
  DateTime? pauseStartTime;
  Duration totalPauseDuration = Duration.zero;
  T? latestData;
  PollError? lastError;

  // Periodic driver
  late final StreamController<void> _tickCtrl;
  StreamSubscription<void>? _sub;

  // Timer & drift keeper
  Timer? _timer;
  final _watch = Stopwatch();

  bool get isDisposed => _disposed;
  bool get isPaused => _paused;
  bool get isRunning => _sub != null;
  Duration? get uptime => startTime == null ? null : DateTime.now().difference(startTime!);
  Duration get currentPauseDuration =>
      _paused && pauseStartTime != null ? DateTime.now().difference(pauseStartTime!) : Duration.zero;

  AsyncSyncResultRepeatEngine({
    required this.name,
    required this.onPoll,
    this.pollingInterval = const Duration(seconds: 10),
    this.enableErrorRecovery = true,
    this.maxRetries = 3,
  }) {
    _validate();
    _initPeriodicStream();
    _start();
  }

  void _validate() {
    if (name.isEmpty) throw ArgumentError('Name cannot be empty');
    if (pollingInterval.inMilliseconds < 100) {
      throw ArgumentError('Polling interval must be at least 100ms');
    }
    if (maxRetries != null && maxRetries! < 0) {
      throw ArgumentError('Max retries must be non-negative');
    }
  }

  // Build a drift-aware periodic stream that respects pause/resume/cancel.
  void _initPeriodicStream() {
    _tickCtrl = StreamController<void>(
      onListen: () {
        if (_disposed) return;
        _watch
          ..reset()
          ..start();
        _scheduleFirstAfter(Duration.zero);
      },
      onPause: () {
        _paused = true;
        pauseStartTime = DateTime.now();
        _watch.stop();
        _timer?.cancel();
        _emitLifecycle(PollEventType.paused, metadata: {
          'pauseStartTime': pauseStartTime!.toIso8601String(),
        });
      },
      onResume: () {
        _paused = false;
        final pdur = pauseStartTime != null ? DateTime.now().difference(pauseStartTime!) : Duration.zero;
        if (pauseStartTime != null) totalPauseDuration += pdur;
        pauseStartTime = null;
        _watch.start();

        // compensate for elapsed within current period
        final elapsed = _watch.elapsed;
        // a - (a / b.abs()).floor() * b.abs() modulo
        final remaining = pollingInterval - (durationModulo(a: elapsed, b: pollingInterval));
        _scheduleFirstAfter(remaining);
        _emitLifecycle(PollEventType.resumed, metadata: {
          'pauseDurationMs': pdur.inMilliseconds,
          'totalPauseDurationMs': totalPauseDuration.inMilliseconds,
        });
      },
      onCancel: () {
        _timer?.cancel();
        _watch.stop();
      },
    );
  }

  void _scheduleFirstAfter(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () {
      if (_disposed) return;
      // fire immediately, then periodic
      _tickCtrl.add(null);
      _timer = Timer.periodic(pollingInterval, (_) => _tickCtrl.add(null));
    });
  }

  void _start() {
    if (_disposed) return;
    startTime = DateTime.now();
    log(name: name, '$name started');
    _emitLifecycle(PollEventType.started, metadata: {
      'pollingIntervalMs': pollingInterval.inMilliseconds,
    });

    // Compose: ticks -> exhaust(onPoll)
    _sub = _tickCtrl.stream.listen((_) async {
      if (_disposed || _paused || _inFlight) return; // exhaust: drop tick if busy
      _inFlight = true;
      try {
        await _executePollWithRetries();
      } finally {
        _inFlight = false;
      }
    });
  }

  Future<void> _executePollWithRetries() async {
    final started = DateTime.now();
    int attempt = 0;
    while (true) {
      try {
        final result = await onPoll(); // await to enforce sequential
        final dur = DateTime.now().difference(started);

        pollCount++;
        lastPollTime = started;
        latestData = result;
        _consecutiveErrors = 0;
        lastError = null;

        _events.add(PollEvent<T>(
          type: PollEventType.success,
          data: result,
          successfulPollCount: pollCount,
          timestamp: started,
          identifier: name,
          status: _paused ? PollStatus.paused : PollStatus.running,
          duration: dur,
        ));
        return;
      } catch (e, st) {
        attempt++;
        _consecutiveErrors++;
        lastError = PollError(e, st, DateTime.now());
        _events.add(PollEvent<T>(
          type: PollEventType.error,
          data: latestData,
          successfulPollCount: pollCount,
          timestamp: DateTime.now(),
          identifier: name,
          status: _paused ? PollStatus.paused : PollStatus.running,
          error: lastError,
        ));

        if (!enableErrorRecovery || (maxRetries != null && attempt > maxRetries!)) {
          log(name: name, 'Max retries exceeded (attempts=$attempt) – giving up for this tick');
          return;
        }
        // Exponential backoff (cap ~32x)
        final factor = attempt > 5 ? 32 : (1 << (attempt - 1));
        await Future.delayed(pollingInterval * factor);
      }
    }
  }

  void pause() => _sub?.pause();

  void resume() => _sub?.resume();

  void updatePollingInterval(Duration newInterval) {
    if (_disposed) return;
    if (newInterval.inMilliseconds < 100) {
      throw ArgumentError('Polling interval must be at least 100ms');
    }
    final old = pollingInterval;
    pollingInterval = newInterval;

    // Rebuild schedule with new interval
    _timer?.cancel();
    if (_sub != null) {
      // If currently paused, keep paused state; on resume we compensate drift again.
      final wasPaused = _paused;
      _sub!.pause();
      _emitLifecycle(PollEventType.intervalChanged, metadata: {
        'oldIntervalMs': old.inMilliseconds,
        'newIntervalMs': newInterval.inMilliseconds,
      });
      _scheduleFirstAfter(Duration.zero);
      if (!wasPaused) _sub!.resume();
    } else {
      _scheduleFirstAfter(Duration.zero);
    }
  }

  void stop() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _sub?.cancel();
    _sub = null;
    log(name: name, '$name stopped');
    _emitLifecycle(PollEventType.stopped);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stop();
    _watch.stop();
    log(name: name, '$name disposed');
    _emitLifecycle(PollEventType.disposed, metadata: {'finalStats': getStats()});
    _events.close();
    _tickCtrl.close();
  }

  Map<String, dynamic> getStats() => {
    'name': name,
    'pollCount': pollCount,
    'isRunning': isRunning,
    'isPaused': _paused,
    'isDisposed': _disposed,
    'startTime': startTime?.toIso8601String(),
    'lastPollTime': lastPollTime?.toIso8601String(),
    'uptimeSec': uptime?.inSeconds,
    'totalPauseDurationSec': totalPauseDuration.inSeconds,
    'currentPauseDurationSec': currentPauseDuration.inSeconds,
    'latestData': latestData,
    'consecutiveErrors': _consecutiveErrors,
    'lastError': lastError?.toString(),
  };

  void _emitLifecycle(PollEventType type, {Map<String, dynamic>? metadata}) {
    if (_disposed || _events.isClosed) return;
    _events.add(PollEvent<T>(
      type: type,
      data: latestData,
      successfulPollCount: pollCount,
      timestamp: DateTime.now(),
      identifier: name,
      status: _paused ? PollStatus.paused : PollStatus.running,
      metadata: metadata,
    ));
  }
}

// Supporting types
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

  PollEvent({
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
  String toString() => 'PollEvent($type, pollCount: $successfulPollCount, data: $data)';
}

class PollError {
  final Object error;
  final StackTrace stackTrace;
  final DateTime timestamp;
  PollError(this.error, this.stackTrace, this.timestamp);
  @override
  String toString() => 'PollError($error at $timestamp)';
}
