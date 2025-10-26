# customized_poll_service

Type-safe, production-friendly polling engines for Dart with structured events, lifecycle control, retries with exponential backoff, backpressure/overflow strategies, drift-aware scheduling, and optional isolate offloading.

This package provides multiple polling engines under a single public entrypoint. Pick the engine that matches your needs:
- AsyncRepeatEngine<T>: queues ticks; sequential processing; emphasizes completeness (no lost ticks, but backlog may grow).
- AsyncSyncResultRepeatEngine<T>: drops ticks while busy (exhaust); emphasizes freshness (latest result, no overlap/backlog).
- AdvancedRepeatEngine<T> (isolate-based): schedules work onto background isolates with optional concurrency and overflow strategies.

All engines emit PollEvent<T> on a broadcast stream with consistent lifecycle semantics and error reporting.

## Overview
- Language/Stack: Dart library package
- SDK: Dart >= 3.8.1 (see pubspec.yaml)
- Public entry point: lib/RepeatEngine.dart
  - Re-exports:
    - src/shared/events.dart: PollEvent, PollEventType, PollStatus, PollError
    - src/AsyncSyncResultRepeatEngine.dart: AsyncSyncResultRepeatEngine
    - src/AsyncRepeatEngine.dart: AsyncRepeatEngine
    - src/IsolateRepeatEngine.dart: AdvancedRepeatEngine, OverflowStrategy
- Package manager: dart pub
- Dev tooling: lints, test

Key capabilities
- Periodic execution with configurable intervals
- Broadcast event streams with structured metadata
- Lifecycle control: start (auto), pause, resume, stop, dispose, interval change
- Retry and exponential backoff with caps
- Backpressure control and overflow strategies (isolate engine)
- Observable statistics and convenience success streams

## Install
Add to your pubspec.yaml (using a local path or your hosted source):

```yaml
dependencies:
  customized_poll_service:
    path: ../customized_poll_service
```

Then run:

```bash
dart pub get
```

## Quick start
Import the single entrypoint and choose an engine.

```dart
import 'package:customized_poll_service/RepeatEngine.dart';

Future<int> fetchNumber() async => 42;

void main() {
  final engine = AsyncRepeatEngine<int>(
    name: 'example',
    pollingInterval: const Duration(seconds: 1),
    onPoll: fetchNumber,
  );

  // Data-only stream of successful results
  final sub = engine.dataStream.listen((value) {
    print('Value: $value');
  });

  // Full event stream (success, error, lifecycle)
  engine.events.listen((e) => print('Event: ${e.type} @ ${e.timestamp}'));

  // Demonstrate pause/resume and interval change
  Future.delayed(const Duration(seconds: 3), () => engine.pause());
  Future.delayed(const Duration(seconds: 4), () => engine.resume());
  Future.delayed(const Duration(seconds: 5), () => engine.updatePollingInterval(const Duration(milliseconds: 500)));

  // Dispose later when done
  Future.delayed(const Duration(seconds: 8), () {
    engine.dispose();
    sub.cancel();
  });
}
```

## Public API via RepeatEngine.dart
RepeatEngine.dart re-exports the following types and classes for your convenience:
- PollEvent<T>, PollEventType, PollStatus, PollError (from src/shared/events.dart)
- AsyncRepeatEngine<T>
- AsyncSyncResultRepeatEngine<T>
- AdvancedRepeatEngine<T>, OverflowStrategy

Recommended import for all usage:

```dart
import 'package:customized_poll_service/RepeatEngine.dart';
```

## Detailed documentation per src file

### 1) src/shared/events.dart
Types that model the polling contract shared by all engines.

- typedef OnPollAction<T> = Future<T> Function();
  - Signature used by AsyncRepeatEngine and AsyncSyncResultRepeatEngine through the shared export.
  - Note: AdvancedRepeatEngine in src/IsolateRepeatEngine.dart defines its own OnPollAction<T> = FutureOr<T> Function() to allow sync work on isolates; you do not need to reference it directly if importing via RepeatEngine.dart.

- enum PollEventType
  - success: A poll completed successfully. data contains the value and duration (if provided by engine) indicates execution time.
  - error: A poll threw; error contains a PollError. data may contain the most recent successful data, if any.
  - started: Engine started.
  - stopped: Engine stopped scheduling new work.
  - paused: Engine paused; scheduling is on hold.
  - resumed: Engine resumed after a pause.
  - reset: Reserved for future use.
  - disposed: Engine disposed; streams close.
  - intervalChanged: Polling interval was updated at runtime.

- enum PollStatus { running, paused, stopped }

- class PollError
  - error: Object thrown
  - stackTrace: StackTrace at the time of error
  - timestamp: DateTime when error occurred

- class PollEvent<T>
  - type: PollEventType
  - data: T? most recent successful data (present for success; may be present for error)
  - successfulPollCount: int counter of successful polls so far
  - timestamp: DateTime when the event occurred
  - identifier: String engine name
  - status: PollStatus at emission time
  - duration: Duration? execution time (engines may provide this)
  - error: PollError? when type == error
  - metadata: Map<String, dynamic>? extra structured info (e.g., intervals, pause durations)

- Duration durationModulo({required Duration a, required Duration b})
  - Utility used by AsyncSyncResultRepeatEngine to keep periodic scheduling aligned (drift-aware computations).

### 2) src/AsyncRepeatEngine.dart
Queue ticks; process sequentially with retries per tick.

- Class: AsyncRepeatEngine<T>
  - Config
    - name: String (required, non-empty)
    - onPoll: OnPollAction<T> (required)
    - pollingInterval: Duration (>= 100 ms; default 10 s)
    - enableErrorRecovery: bool (default true)
    - maxRetries: int? (default 3; null = unlimited)
  - Streams
    - events: Stream<PollEvent<T>> (broadcast)
    - dataStream: Stream<T> of successful results (convenience)
  - State/Stats
    - pollCount, lastPollTime, startTime, latestData, lastError
  - Behavior
    - Internally uses Stream.periodic(pollingInterval) and asyncMap to process each tick sequentially.
    - While a poll is running, subsequent ticks are queued by asyncMap; work does not overlap.
    - On error, emits an error PollEvent and optionally retries with exponential backoff: delays are pollingInterval * {1, 2, 4, 8, 16, 32 cap} up to maxRetries attempts for that tick, then gives up that tick.
  - Lifecycle
    - pause(): pauses underlying subscription and emits paused
    - resume(): resumes and emits resumed
    - updatePollingInterval(Duration): validates (>= 100 ms), emits intervalChanged with old/new, restarts internal scheduling
    - stop(): cancels periodic subscription and emits stopped (engine can be restarted by updatePollingInterval() which invokes _start; dispose to end fully)
    - dispose(): stops, emits disposed, and closes streams

Typical usage:

```dart
final engine = AsyncRepeatEngine<String>(
  name: 'queued',
  pollingInterval: const Duration(milliseconds: 250),
  onPoll: () async {
    await Future.delayed(const Duration(milliseconds: 400));
    return 'value';
  },
);
```

### 3) src/AsyncSyncResultRepeatEngine.dart
Drop ticks while busy (“exhaust” behavior); emphasizes freshness. Also features drift-aware periodic scheduling and pause/resume with accumulated pause time.

- Class: AsyncSyncResultRepeatEngine<T>
  - Config
    - name: String (required)
    - onPoll: OnPollAction<T> (required)
    - pollingInterval: Duration (>= 100 ms; default 10 s)
    - enableErrorRecovery: bool (default true)
    - maxRetries: int? (default 3; null = unlimited)
  - Streams
    - events: Stream<PollEvent<T>> (broadcast)
    - dataStream: Stream<T> of successful results
  - State/Stats getters
    - isDisposed, isPaused, isRunning
    - uptime: Duration? since start
    - currentPauseDuration: Duration of ongoing pause
    - pollCount, lastPollTime, latestData, lastError
  - Behavior
    - Builds a custom periodic driver with Timer that fires immediately and then every pollingInterval.
    - If a tick arrives while onPoll is still running, the tick is dropped (no queuing), guaranteeing no overlap and no backlog.
    - Retries per tick with exponential backoff like AsyncRepeatEngine, respecting enableErrorRecovery and maxRetries.
    - Pause/resume updates internal stopwatch and compensates drift on resume so the schedule stays aligned to the original cadence.
  - Lifecycle
    - pause(): pauses via stream subscription; emits paused
    - resume(): resumes; emits resumed
    - updatePollingInterval(Duration): validates and rebuilds timing; emits intervalChanged with old/new
    - dispose(): stops timers/subscriptions; emits disposed and closes streams

Typical usage:

```dart
final engine = AsyncSyncResultRepeatEngine<int>(
  name: 'freshness',
  pollingInterval: const Duration(milliseconds: 100),
  onPoll: () async {
    await Future.delayed(const Duration(milliseconds: 250));
    return 1;
  },
);
```

### 4) src/IsolateRepeatEngine.dart
Offload work to background isolates, with optional concurrency and backpressure strategies.

- enum OverflowStrategy
  - unbounded: no limit on queue length
  - dropOldest: when full, drop the oldest queued job, enqueue the new one
  - dropNewest: when full, drop the new tick
  - skipIfBusy: if the queue is at capacity, skip scheduling a tick
  - coalesceLatest: at most one pending job at any time (new ticks coalesce)

- class AdvancedRepeatEngine<T>
  - Config
    - name: String (required)
    - onPoll: FutureOr<T> Function() (its own OnPollAction supporting sync or async)
    - pollingInterval: Duration (>= 10 ms; default 10 s)
    - runUntilDisposed: bool (default true)
    - enableErrorRecovery: bool (default true)
    - maxRetries: int? (default 3; null = unlimited)
    - concurrency: int (# of worker loops). Defaults to Platform.numberOfProcessors - 1, clamped to [1, cores]
    - queueCapacity: int? (default 10; null = unbounded)
    - overflow: OverflowStrategy (default unbounded)
  - Streams
    - events: Stream<PollEvent<T>>
    - successStream: Stream<T> of successful results
  - State/Stats
    - getStats(): Map<String, dynamic> exposing counters and flags (pollCount, pause durations, queue length, lastError, etc.)
  - Behavior
    - A scheduler Timer enqueues jobs at each interval and a pool of worker loops consumes them.
    - Each job executes on an isolate via Isolate.run to keep the main isolate responsive.
    - Error handling with optional backoff; when recovery disabled or retries exceeded, the engine stops scheduling (workers drain and exit).
  - Lifecycle
    - pause()/resume(): toggles paused state and emits lifecycle events with pause durations
    - updatePollingInterval(Duration): validates (>= 10 ms), restarts scheduler, emits intervalChanged with old/new
    - stop(): stops scheduling and emits stopped
    - dispose(): cancels everything, emits disposed (with finalStats), closes stream

Typical usage:

```dart
final engine = AdvancedRepeatEngine<int>(
  name: 'isolate-engine',
  pollingInterval: const Duration(milliseconds: 150),
  concurrency: 2,
  onPoll: () => heavySyncComputation(), // runs off the main isolate
);
```

### 5) src/demo/*.dart
Runnable demos illustrating each engine.

- demo_async_queue.dart (AsyncRepeatEngine)
  - Shows queued ticks with sequential processing; pause/resume while backlog builds and drains.
  - Run: `dart run lib/src/demo/demo_async_queue.dart`

- demo_async_sync.dart (AsyncSyncResultRepeatEngine)
  - Shows drop-while-busy (exhaust) behavior vs theoretical tick count.
  - Run: `dart run lib/src/demo/demo_async_sync.dart`

- demo_isolate.dart (AdvancedRepeatEngine)
  - Heavy CPU work off the main isolate; demonstrates success/error event handling.
  - Run: `dart run lib/src/demo/demo_isolate.dart`

## Additional guidance
- Picking an engine
  - Prefer AsyncRepeatEngine when you want to eventually run every scheduled tick (sequentially) even if processing lags; useful for completeness.
  - Prefer AsyncSyncResultRepeatEngine when you only care about the most recent result and want to avoid backlog; useful for freshness.
  - Prefer AdvancedRepeatEngine when work is CPU-heavy or blocking and you need to keep the main isolate responsive, optionally with concurrency and backpressure control.

- Error handling
  - All engines emit PollEventType.error with a PollError containing the thrown error, stack trace, and timestamp.
  - Retrying/backoff is per-tick; if retries are exhausted for a tick, that tick is given up, and scheduling continues (except AdvancedRepeatEngine may stop when recovery is disabled and errors persist).

- Lifecycle events and metadata
  - Engines emit started, paused, resumed, intervalChanged, stopped, disposed.
  - Metadata maps include helpful details such as old/new intervals and pause durations.

- Streams
  - Subscribe to events for detailed lifecycle and error visibility.
  - Subscribe to dataStream/successStream for successful values only.

## Commands
- Get dependencies: `dart pub get`
- Analyze: `dart analyze`
- Format: `dart format .`
- Run demos:
  - `dart run lib/src/demo/demo_async_queue.dart`
  - `dart run lib/src/demo/demo_async_sync.dart`
  - `dart run lib/src/demo/demo_isolate.dart`

## Project structure
```
customized_poll_service/
├─ lib/
│  ├─ RepeatEngine.dart                        # Public entrypoint (re-exports)
│  └─ src/
│     ├─ shared/
│     │  └─ events.dart                        # PollEvent types and helpers
│     ├─ AsyncRepeatEngine.dart                # Queue ticks; sequential jobs
│     ├─ AsyncSyncResultRepeatEngine.dart      # Drop-while-busy; drift-aware
│     ├─ IsolateRepeatEngine.dart              # AdvancedRepeatEngine + overflow
│     └─ demo/
│        ├─ demo_async_queue.dart              # Demo for AsyncRepeatEngine
│        ├─ demo_async_sync.dart               # Demo for AsyncSyncResultRepeatEngine
│        └─ demo_isolate.dart                  # Demo for AdvancedRepeatEngine
├─ fair_comparison.dart                        # Optional utility/benchmark
├─ pubspec.yaml                                # Package metadata
├─ analysis_options.yaml                       # Lint rules
├─ CHANGELOG.md
└─ README.md
```

## Changelog
See CHANGELOG.md.

## License
A license file is not present in this repository.
- Consider adding a LICENSE (e.g., MIT or Apache-2.0) if you plan to publish.

## Contributing and issues
- Please run `dart analyze` and `dart format .` before sending PRs.
- File issues/requests in your chosen tracker (e.g., GitHub Issues).
