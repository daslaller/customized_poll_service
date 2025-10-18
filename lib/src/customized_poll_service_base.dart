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

/// Signature for the user-supplied polling callback.
///
/// The function is executed in a separate isolate by default, so it should be
/// reasonably self-contained and not capture large object graphs. It may return
/// either a value of type `T` synchronously or a `Future<T>` asynchronously.
/// Throwing an error will emit a [PollEventType.error] and may trigger retries
/// depending on configuration.
typedef OnPollAction<T> = FutureOr<T> Function();

/// Types of events emitted by [RepeatEngine] on the `events` stream.
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

/// High-level status of the engine when an event was emitted.
///
/// - [running]: The engine is active and scheduling work.
/// - [paused]: The engine is paused; no new jobs are enqueued.
/// - [stopped]: The engine has been stopped or disposed.
enum PollStatus { running, paused, stopped }

/// Strategy used when the pending job queue reaches capacity.
///
/// - [unbounded]: No limit on queue length (ignore `queueCapacity`).
/// - [dropOldest]: Remove the oldest pending job, then add the new one.
/// - [dropNewest]: Drop the new job when at capacity; keep existing ones.
/// - [skipIfBusy]: If workers are busy (queue is full), skip scheduling this tick.
/// - [coalesceLatest]: Ensure at most one pending job is queued. Useful when only
///   the latest result matters (frame coalescing behavior).
enum OverflowStrategy {
  unbounded,
  dropOldest,
  dropNewest,
  skipIfBusy,
  coalesceLatest,
}

/// Wraps an error thrown by the polling function along with its stack trace
/// and the time it occurred.
class PollError {
  /// The error object thrown by the user callback.
  final Object error;

  /// The stack trace captured at the error site.
  final StackTrace stackTrace;

  /// Timestamp when the error occurred.
  final DateTime timestamp;

  PollError(this.error, this.stackTrace, this.timestamp);

  @override
  String toString() => 'PollError($error at $timestamp)';
}

/// An event emitted by [RepeatEngine] representing either a successful poll,
/// an error, or a lifecycle change.
class PollEvent<T> {
  /// The kind of event (success, error, started, etc.).
  final PollEventType type;

  /// The payload for success events. For non-success events this may contain the
  /// latest known successful data for convenience.
  final T? data;

  /// Total number of successful polls observed so far.
  final int successfulPollCount;

  /// The time this event was produced.
  final DateTime timestamp;

  /// Engine identifier (the [RepeatEngine.name]).
  final String identifier;

  /// Engine status at the time of emission.
  final PollStatus status;

  /// Execution time of the poll for [PollEventType.success]. Null otherwise.
  final Duration? duration;

  /// Error details for [PollEventType.error]. Null otherwise.
  final PollError? error;

  /// Additional context specific to the event (e.g., interval change details).
  final Map<String, dynamic>? metadata;

  /// Creates a new [PollEvent]. Library code constructs these for you.
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
}

/// A configurable, concurrent polling engine.
///
/// RepeatEngine schedules repeated execution of [onPoll] at [pollingInterval].
/// It supports running with multiple workers, queue overflow strategies, error
/// recovery with exponential backoff, and lifecycle controls (pause/resume/stop
/// /dispose). Events are emitted via [events] for success, error, and lifecycle
/// notifications. See top-of-file docs for a usage example.
class RepeatEngine<T> {
  // Config
  /// A human-readable name used for logs and event identifiers.
  final String name;

  /// The user callback executed on each poll cycle.
  final OnPollAction<T> onPoll;

  /// Current polling interval. Can be changed at runtime via
  /// [updatePollingInterval].
  Duration pollingInterval;

  /// Number of worker loops concurrently consuming jobs.
  final int concurrency; // number of workers

  /// If true, engine keeps running until explicitly disposed/stopped.
  final bool runUntilDisposed, enableErrorRecovery;

  /// Max consecutive error retries before stopping. Null = unlimited.
  final int? maxRetries, queueCapacity;

  /// Queue overflow policy applied when [queueCapacity] is reached.
  final OverflowStrategy overflow;

  // Streams
  final _events = StreamController<PollEvent<T>>.broadcast();

  /// Stream of all events produced by the engine. This includes successes,
  /// errors, and lifecycle events. Use `listen` with appropriate filtering.
  Stream<PollEvent<T>> get events => _events.stream;

  /// Convenience stream that emits only successful results of type [T].
  /// Note: this stream will not emit lifecycle or error events.
  Stream<T> get successStream => events
      .where((e) => e.type == PollEventType.success && e.data != null)
      .map((e) => e.data as T);

  // State
  Timer? _timer;
  bool _disposed = false, _paused = false;
  int _consecutiveErrors = 0, pollCount = 0;
  DateTime? lastPollTime, startTime, pauseStartTime;
  Duration totalPauseDuration = Duration.zero;
  T? latestData;
  PollError? lastError;

  // Queue & workers
  final _queue = ListQueue<_Job>();
  late final List<Future<void>> _workers;

  /// True once [dispose] has been called or the engine has been stopped.
  bool get isDisposed => _disposed;

  /// True when the engine is paused via [pause].
  bool get isPaused => _paused;

  /// True while the periodic timer is active and the engine is not disposed.
  bool get isRunning => _timer?.isActive == true && !_disposed;

  /// Total time since [startTime], excluding pauses can be derived from
  /// [uptime] minus [totalPauseDuration]. Null until started.
  Duration? get uptime =>
      startTime == null ? null : DateTime.now().difference(startTime!);

  /// Duration of the current pause window, or zero if not paused.
  Duration get currentPauseDuration => _paused && pauseStartTime != null
      ? DateTime.now().difference(pauseStartTime!)
      : Duration.zero;

  /// Creates a new [RepeatEngine].
  ///
  /// Parameters:
  /// - [name]: A human-readable identifier for logs and events.
  /// - [onPoll]: The callback to invoke each tick. Executed in an isolate.
  /// - [pollingInterval]: Initial interval between polls (>= 10 ms).
  /// - [runUntilDisposed]: If true, continues until [dispose] is called.
  /// - [enableErrorRecovery]: If true, retries with exponential backoff on errors.
  /// - [maxRetries]: Max consecutive errors before [stop] is called. Null = unlimited.
  /// - [concurrency]: Number of worker loops. Defaults to `max(1, cores-1)`.
  /// - [queueCapacity]: Max pending jobs; null means unbounded.
  /// - [overflow]: Policy applied when the queue is at capacity.
  RepeatEngine({
    required this.name,
    required this.onPoll,
    this.pollingInterval = const Duration(seconds: 10),
    this.runUntilDisposed = true,
    this.enableErrorRecovery = true,
    this.maxRetries = 3,
    int? concurrency, // set >1 if you want overlapping jobs by design
    this.queueCapacity = 10, // e.g., 1000
    this.overflow = OverflowStrategy.unbounded,
  }) : concurrency =
           concurrency ??
           (Platform.numberOfProcessors - 1).clamp(
             1,
             Platform.numberOfProcessors,
           ) {
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
      PollEventType.started,
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
    // Coalesce means "ensure at most one pending job" (framebuffer-like)
    if (overflow == OverflowStrategy.coalesceLatest) {
      if (_queue.isEmpty) {
        _queue.add(_Job());
      } // else: one pending already; do nothing
      return;
    }

    if (queueCapacity == null) {
      // Unbounded
      _queue.add(_Job());
      return;
    } else if (_queue.length < queueCapacity!) {
      // Bounded policies
      _queue.add(_Job());
      return;
    }

    switch (overflow) {
      case OverflowStrategy.dropOldest:
        _queue.removeFirst();
        _queue.add(_Job());
        break;
      case OverflowStrategy.unbounded:
      default:
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
          PollEvent<T>(
            type: PollEventType.success,
            data: result,
            successfulPollCount: pollCount,
            timestamp: started,
            identifier: name,
            status: _paused ? PollStatus.paused : PollStatus.running,
            duration: dur,
          ),
        );
      } catch (e, st) {
        _consecutiveErrors++;
        lastError = PollError(e, st, DateTime.now());
        _events.add(
          PollEvent<T>(
            type: PollEventType.error,
            data: latestData,
            successfulPollCount: pollCount,
            timestamp: DateTime.now(),
            identifier: name,
            status: _paused ? PollStatus.paused : PollStatus.running,
            error: lastError,
          ),
        );

        if (enableErrorRecovery &&
            (maxRetries == null || _consecutiveErrors <= maxRetries!)) {
          // simple exponential backoff capped at 32x
          final factor = (_consecutiveErrors > 5)
              ? 32
              : (1 << (_consecutiveErrors - 1));
          await Future.delayed(pollingInterval * factor);
        } else {
          // stop scheduling new jobs; workers will drain queue and exit
          stop();
        }
      }
    }
  }

  /// Runs the user function in an ephemeral isolate to avoid blocking the main
  /// isolate. For very high rates, consider swapping this for a real isolate pool;
  /// the API stays the same.
  static Future<R> _runInIsolate<R>(FutureOr<R> Function() fn) {
    return Isolate.run<R>(() => fn());
  }

  /// Pauses the engine. No new jobs will be enqueued until [resume] is called.
  /// Emits a [PollEventType.paused] lifecycle event.
  void pause() {
    if (_disposed || _paused) return;
    _paused = true;
    pauseStartTime = DateTime.now();
    log(name: name, '$name paused');
    _emitLifecycle(
      PollEventType.paused,
      metadata: {'pauseStartTime': pauseStartTime!.toIso8601String()},
    );
  }

  /// Resumes the engine after a [pause]. Emits a [PollEventType.resumed]
  /// lifecycle event and accounts for pause durations in [totalPauseDuration].
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
      PollEventType.resumed,
      metadata: {
        'pauseDurationMs': pdur.inMilliseconds,
        'totalPauseDurationMs': totalPauseDuration.inMilliseconds,
      },
    );
  }

  /// Updates the polling interval at runtime. The internal timer is restarted
  /// immediately to apply the new interval, and an [intervalChanged] event is
  /// emitted with metadata containing old and new values.
  void updatePollingInterval(Duration newInterval) {
    if (_disposed) return;
    if (newInterval.inMilliseconds < 10) {
      throw ArgumentError('Polling interval must be >= 10 ms');
    }
    final old = pollingInterval;
    pollingInterval = newInterval;
    // Restart timer to apply immediately
    _timer?.cancel();
    _timer = Timer.periodic(pollingInterval, (_) {
      if (_disposed || _paused) return;
      _enqueueJob();
    });
    _emitLifecycle(
      PollEventType.intervalChanged,
      metadata: {
        'oldIntervalMs': old.inMilliseconds,
        'newIntervalMs': newInterval.inMilliseconds,
      },
    );
  }

  /// Stops scheduling new jobs and cancels the timer. Workers will drain any
  /// queued jobs and then exit. Emits a [PollEventType.stopped] event.
  void stop() {
    if (_disposed) return;
    log(name: name, '$name stopped');
    _emitLifecycle(PollEventType.stopped);
    _disposed = true;
    _timer?.cancel();
  }

  /// Disposes the engine, canceling timers and closing the event stream.
  /// Emits a final [PollEventType.disposed] event with summary stats.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    log(name: name, '$name disposed');
    _timer?.cancel();
    _emitLifecycle(
      PollEventType.disposed,
      metadata: {'finalStats': getStats()},
    );
    _events.close();
  }

  /// Returns a snapshot of internal counters and timing, useful for diagnostics
  /// or logging. Keys include: name, pollCount, isRunning, isPaused, isDisposed,
  /// startTime, lastPollTime, uptimeSec, totalPauseDurationSec,
  /// currentPauseDurationSec, latestData, consecutiveErrors, lastError,
  /// queueLength, overflow, concurrency.
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

  void _emitLifecycle(PollEventType type, {Map<String, dynamic>? metadata}) {
    if (_disposed || _events.isClosed) return;
    _events.add(
      PollEvent<T>(
        type: type,
        data: latestData,
        successfulPollCount: pollCount,
        timestamp: DateTime.now(),
        identifier: name,
        status: _paused ? PollStatus.paused : PollStatus.running,
        metadata: metadata,
      ),
    );
  }
}

class _Job {}
