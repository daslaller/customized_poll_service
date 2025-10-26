/// Customized Poll Service - Core RepeatEngine
///
/// This file implements a highly-configurable, production-friendly polling engine
/// that repeatedly executes a user-supplied function on a schedule. It supports:
/// - Backpressure via queue with multiple overflow strategies
/// - Concurrency (multiple workers) without overlapping critical sections
/// - Pause/resume/stop/dispose lifecycle controls
/// - Error reporting with retry and exponential backoff
/// - Emission of structured events for successes, errors, and lifecycle changes
/// - Dynamic interval updates at runtime
/// - Uptime and pause time tracking for observability
///
/// The engine executes the user callback in an ephemeral Isolate by default to
/// prevent blocking the main isolate. This design keeps UI and I/O responsive
/// while your polling job can be CPU- or latency-heavy.
///
/// Typical usage:
///
///   final engine = RepeatEngine<int>(
///     name: 'example',
///     pollingInterval: Duration(seconds: 2),
///     onPoll: () async => await fetchCount(),
///     concurrency: 2, // optional, defaults to #cores-1
///     overflow: OverflowStrategy.coalesceLatest,
///   );
///
///   engine.events.listen((e) {
///     switch (e.type) {
///       case PollEventType.success:
///         print('value: \\${e.data} in \\${e.duration}');
///         break;
///       case PollEventType.error:
///         print('error: \\${e.error}');
///         break;
///       default:
///         print('lifecycle: \\${e.type} meta=\\${e.metadata}');
///     }
///   });
///
///   // Later
///   engine.pause();
///   engine.resume();
///   engine.updatePollingInterval(Duration(milliseconds: 500));
///   engine.dispose();
///
/// Note on isolates: The supplied onPoll function should be reasonably
/// self-contained (no deep closures on large object graphs) because it executes
/// in a separate isolate. For extremely high rates, consider replacing
/// _runInIsolate with a pooled approach.
import 'dart:async';
import 'dart:collection';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';
import 'shared/events.dart' as ev;
/// Signature for the user-supplied polling callback.
///
/// The function is executed in a separate isolate by default, so it should be
/// reasonably self-contained and not capture large object graphs. It may return
/// either a value of type `T` synchronously or a `Future<T>` asynchronously.
/// Throwing an error will emit a [PollEventType.error] and may trigger retries
/// depending on configuration.
typedef OnPollAction<T> = FutureOr<T> Function();

/// Types of events emitted by [AdvancedRepeatEngine] on the `events` stream.
///
/// - [success]: A poll completed successfully. `data` contains the value and
///   `duration` indicates execution time.
/// - [error]: A poll threw. `error` contains the error and stack; `data` may
///   contain the last successful data (if any) for convenience.
/// - [started]: Engine started scheduling work.
/// - [stopped]: Engine stopped scheduling new work (workers drain pending jobs).
/// - [paused]: Engine paused; workers sleep and no jobs are enqueued.
/// - [resumed]: Engine resumed after a pause.
/// - [reset]: Reserved for future use (not emitted in current implementation).
/// - [disposed]: Engine disposed; streams close and timer cancelled.
/// - [intervalChanged]: Polling interval was updated at runtime.

// --------------------------------- Public API --------------------------------
enum OverflowStrategy {
  unbounded,
  dropOldest,
  dropNewest,
  skipIfBusy,
  coalesceLatest,
}

class AdvancedRepeatEngine<T> {
  // Config
  final String name;
  final OnPollAction<T> onPoll;
  Duration pollingInterval;
  final int concurrency; // number of workers
  final bool runUntilDisposed, enableErrorRecovery;
  final int? maxRetries, queueCapacity;
  final OverflowStrategy overflow;

  // Streams
  final _events = StreamController<ev.PollEvent<T>>.broadcast();
  Stream<ev.PollEvent<T>> get events => _events.stream;
  Stream<T> get successStream => _events.stream
      .where((e) => e.type == ev.PollEventType.success && e.data != null)
      .map((e) => e.data as T);

  // State
  Timer? _timer;
  bool _disposed = false, _paused = false;
  int _consecutiveErrors = 0, pollCount = 0;
  DateTime? lastPollTime, startTime, pauseStartTime;
  Duration totalPauseDuration = Duration.zero;
  T? latestData;
  ev.PollError? lastError;

  // Queue & workers
  final _queue = ListQueue<_Job>();
  late final List<Future<void>> _workers;

  bool get isDisposed => _disposed;
  bool get isPaused => _paused;
  bool get isRunning => _timer?.isActive == true && !_disposed;

  Duration? get uptime =>
      startTime == null ? null : DateTime.now().difference(startTime!);

  Duration get currentPauseDuration => _paused && pauseStartTime != null
      ? DateTime.now().difference(pauseStartTime!)
      : Duration.zero;

  AdvancedRepeatEngine({
    required this.name,
    required this.onPoll,
    this.pollingInterval = const Duration(seconds: 10),
    this.runUntilDisposed = true,
    this.enableErrorRecovery = true,
    this.maxRetries = 3,
    int? concurrency,
    this.queueCapacity = 10,
    this.overflow = OverflowStrategy.unbounded,
  }) : concurrency = concurrency ??
      (Platform.numberOfProcessors - 1)
          .clamp(1, Platform.numberOfProcessors) {
    _validate();
    _start();
  }

  void _validate() {
    if (name.isEmpty) throw ArgumentError('Name cannot be empty');
    if (pollingInterval.inMilliseconds < 10) {
      throw ArgumentError('Polling interval must be >= 10 ms');
    }
    if (concurrency < 1) throw ArgumentError('Concurrency must be >= 1');
    if (queueCapacity != null && queueCapacity! < 1) {
      throw ArgumentError('queueCapacity must be >= 1 or null');
    }
  }

  void _start() {
    startTime = DateTime.now();
    log(name: name, '$name started');
    _emitLifecycle(
      ev.PollEventType.started,
      metadata: {
        'pollingIntervalMs': pollingInterval.inMilliseconds,
        'concurrency': concurrency,
        'overflow': overflow.toString(),
        'queueCapacity': queueCapacity,
      },
    );

    // Start workers
    _workers = List.generate(concurrency, (_) => _workerLoop());

    // Start scheduler
    _timer = Timer.periodic(pollingInterval, (_) {
      if (_disposed || _paused) return;
      _enqueueJob();
    });
  }

  void _enqueueJob() {
    // Coalesce: at most one pending job
    if (overflow == OverflowStrategy.coalesceLatest) {
      if (_queue.isEmpty) _queue.add(_Job());
      return;
    }

    if (queueCapacity == null) {
      _queue.add(_Job());
      return;
    }

    if (_queue.length < queueCapacity!) {
      _queue.add(_Job());
      return;
    }

    switch (overflow) {
      case OverflowStrategy.dropOldest:
        _queue.removeFirst();
        _queue.add(_Job());
        break;
      case OverflowStrategy.dropNewest:
      // drop this tick
        break;
      case OverflowStrategy.skipIfBusy:
      // queue full => busy; skip this tick
        break;
      case OverflowStrategy.unbounded:
      case OverflowStrategy.coalesceLatest:
      // handled above / not reached
        break;
    }
  }

  Future<void> _workerLoop() async {
    while (!_disposed) {
      if (_paused) {
        await Future.delayed(const Duration(milliseconds: 20));
        continue;
      }
      final job = _queue.isEmpty ? null : _queue.removeFirst();
      if (job == null) {
        await Future.delayed(const Duration(milliseconds: 5));
        continue;
      }

      final started = DateTime.now();
      try {
        final result = await _runInIsolate<T>(onPoll);
        final dur = DateTime.now().difference(started);

        pollCount++;
        lastPollTime = started;
        latestData = result;
        _consecutiveErrors = 0;
        lastError = null;

        _events.add(
          ev.PollEvent<T>(
            type: ev.PollEventType.success,
            data: result,
            successfulPollCount: pollCount,
            timestamp: started,
            identifier: name,
            status: _paused ? ev.PollStatus.paused : ev.PollStatus.running,
            duration: dur,
          ),
        );
      } catch (e, st) {
        _consecutiveErrors++;
        lastError = ev.PollError(e, st, DateTime.now());
        _events.add(
          ev.PollEvent<T>(
            type: ev.PollEventType.error,
            data: latestData,
            successfulPollCount: pollCount,
            timestamp: DateTime.now(),
            identifier: name,
            status: _paused ? ev.PollStatus.paused : ev.PollStatus.running,
            error: lastError,
          ),
        );

        if (enableErrorRecovery &&
            (maxRetries == null || _consecutiveErrors <= maxRetries!)) {
          final factor =
          (_consecutiveErrors > 5) ? 32 : (1 << (_consecutiveErrors - 1));
          await Future.delayed(pollingInterval * factor);
        } else {
          stop(); // stop scheduling; workers will drain queue and exit
        }
      }
    }
  }

  static Future<R> _runInIsolate<R>(FutureOr<R> Function() fn) {
    return Isolate.run<R>(() => fn());
  }

  void pause() {
    if (_disposed || _paused) return;
    _paused = true;
    pauseStartTime = DateTime.now();
    log(name: name, '$name paused');
    _emitLifecycle(
      ev.PollEventType.paused,
      metadata: {'pauseStartTime': pauseStartTime!.toIso8601String()},
    );
  }

  void resume() {
    if (_disposed || !_paused) return;
    final pdur = pauseStartTime != null
        ? DateTime.now().difference(pauseStartTime!)
        : Duration.zero;
    _paused = false;
    if (pauseStartTime != null) totalPauseDuration += pdur;
    pauseStartTime = null;
    log(name: name, '$name resumed');
    _emitLifecycle(
      ev.PollEventType.resumed,
      metadata: {
        'pauseDurationMs': pdur.inMilliseconds,
        'totalPauseDurationMs': totalPauseDuration.inMilliseconds,
      },
    );
  }

  void updatePollingInterval(Duration newInterval) {
    if (_disposed) return;
    if (newInterval.inMilliseconds < 10) {
      throw ArgumentError('Polling interval must be >= 10 ms');
    }
    final old = pollingInterval;
    pollingInterval = newInterval;

    _timer?.cancel();
    _timer = Timer.periodic(pollingInterval, (_) {
      if (_disposed || _paused) return;
      _enqueueJob();
    });

    _emitLifecycle(
      ev.PollEventType.intervalChanged,
      metadata: {
        'oldIntervalMs': old.inMilliseconds,
        'newIntervalMs': newInterval.inMilliseconds,
      },
    );
  }

  void stop() {
    if (_disposed) return;
    log(name: name, '$name stopped');
    _emitLifecycle(ev.PollEventType.stopped);
    _disposed = true;
    _timer?.cancel();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    log(name: name, '$name disposed');
    _timer?.cancel();
    _emitLifecycle(
      ev.PollEventType.disposed,
      metadata: {'finalStats': getStats()},
    );
    _events.close();
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
    'queueLength': _queue.length,
    'overflow': overflow.toString(),
    'concurrency': concurrency,
  };

  void _emitLifecycle(ev.PollEventType type, {Map<String, dynamic>? metadata}) {
    if (_disposed || _events.isClosed) return;
    _events.add(
      ev.PollEvent<T>(
        type: type,
        data: latestData,
        successfulPollCount: pollCount,
        timestamp: DateTime.now(),
        identifier: name,
        status: _paused ? ev.PollStatus.paused : ev.PollStatus.running,
        metadata: metadata,
      ),
    );
  }
}

class _Job {}

