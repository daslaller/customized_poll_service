# customized_poll_service

Enhanced, type-safe polling service for Dart with robust error handling, lifecycle events, backpressure/overflow strategies, and performance monitoring.

This package provides a RepeatEngine<T> you can configure to periodically execute a function, stream results, and react to lifecycle events (start/stop/pause/resume/reset/interval change). It is suitable for periodic data fetching, background tasks, or any repeatable work.

## Overview
- Language/Stack: Dart library package
- SDK: Dart >= 3.8.1 (see pubspec.yaml)
- Entry point (library): `lib/customized_poll_service.dart`
  - Exposes `RepeatEngine<T>` from `lib/src/customized_poll_service_base.dart`
- Package manager: `dart pub`
- No runtime dependencies; dev dependencies: `lints`, `test`

Key capabilities:
- Periodic execution with configurable interval and concurrency
- Emits structured events with metadata via a broadcast stream
- Lifecycle control: start (auto), pause, resume, reset, stop, dispose
- Error handling and optional exponential backoff with retry limits
- Backpressure control via queue capacity and overflow strategies
- Observable statistics and convenience data stream of successful results

## Requirements
- Dart SDK ^3.8.1
- Platform: Any platform supported by Dart VM
- No external services or environment variables required

## Installation
If used as a dependency in another Dart project, add to your pubspec.yaml:

```yaml
dependencies:
  customized_poll_service:
    path: ../customized_poll_service  # or use your hosted source when published
```

Then run:

```bash
dart pub get
```

## Quick start
Minimal example creating a polling engine that runs every second and logs results.

```dart
import 'package:customized_poll_service/IsolateRepeatEngine.dart';

Future<String> fetch() async => 'Data: ${DateTime.now().toIso8601String()}';

void main() async {
  final engine = RepeatEngine<String>(
    name: 'DemoService',
    onPoll: fetch,                  // Your async or sync function
    pollingInterval: Duration(seconds: 1),
    runUntilDisposed: true,
    enableErrorRecovery: true,
    maxRetries: 3,
    // concurrency: 1,              // Optional: number of worker loops
    // queueCapacity: null,         // Optional: unbounded by default
    // overflow: OverflowStrategy.unbounded,
  );

  // Subscribe to high-level "data only" stream of successful polls
  final sub = engine.dataStream.listen((data) {
    print('New data: $data');
  });

  // Subscribe to full event stream (includes lifecycle & errors)
  engine.events.listen((event) => print('Event: ${event.type} @ ${event.timestamp}'));

  // Keep the process alive until disposed
  await engine.keepAlive; // If you manage lifecycle yourself, call dispose() when done
  await sub.cancel();
}
```

A more complete runnable demo is available at `lib/src/test.dart`.

Run it with:

```bash
dart run lib/src/test.dart
```

## Usage notes and API highlights
Constructor:

Parameters (constructor):
- name: String (required)
- onPoll: OnPollAction<T> (required) — async or sync function returning T
- pollingInterval: Duration, default 10s
- runUntilDisposed: bool, default true
- enableErrorRecovery: bool, default true
- maxRetries: int? (null = unlimited), default 3
- concurrency: int, default 1
- queueCapacity: int? (null = unbounded)
- overflow: OverflowStrategy, default OverflowStrategy.unbounded

Common methods:
- `pause()` / `resume()`
- `reset()`
- `updatePollingInterval(Duration newInterval)`
- `stop()` and `dispose()`
- Streams: `events` (all `PollEvent<T>`), `dataStream` (successful `T` only)
- Stats: `getStats()` returns a map of current counters/flags

Backpressure and overflow:
- `queueCapacity`: maximum pending jobs (null means unbounded)
- `overflow` strategies:
  - `unbounded`: no limit
  - `dropOldest`: drop the oldest queued job when full
  - `dropNewest`: drop the newly produced job when full
  - `skipIfBusy`: skip scheduling when queue is full
  - `coalesceLatest`: ensure at most one pending job at a time

Error recovery:
- When `enableErrorRecovery` is true, transient failures cause exponential backoff up to a cap, controlled by `maxRetries` (null means unlimited retries).

## Scripts and commands
This repo doesn’t define custom pub scripts. Useful commands:
- Get dependencies: `dart pub get`
- Analyze (uses `analysis_options.yaml`): `dart analyze`
- Format: `dart format .`
- Run demo: `dart run lib/src/test.dart`
- Run comparison benchmark (optional utility): `dart run fair_comparison.dart`

## Environment variables
None required by default.
- TODO: Document any env vars if your onPoll uses external services (e.g., API keys).

## Testing
The repo includes the `test` dev dependency but currently has no tests in a `test/` directory.
- TODO: Add tests under `test/` and run with:

```bash
dart test
```

## Project structure
```
customized_poll_service/
├─ lib/
│  ├─ customized_poll_service.dart           # Library entry point (exports src)
│  └─ src/
│     ├─ customized_poll_service_base.dart   # RepeatEngine implementation
│     └─ test.dart                           # Runnable demo
├─ fair_comparison.dart                      # Utility for memory/perf comparison
├─ pubspec.yaml                              # Package metadata
├─ analysis_options.yaml                     # Lint rules
├─ CHANGELOG.md
└─ README.md
```

## Changelog
See [CHANGELOG.md](CHANGELOG.md).

## License
A license file is not present in this repository.
- TODO: Add a LICENSE file (e.g., MIT, Apache-2.0) and update this section.

## Contributing and issues
- Issues: TODO add issue tracker link (e.g., GitHub issues URL)
- Contributions are welcome. Please run `dart analyze` and `dart format .` before submitting PRs.
