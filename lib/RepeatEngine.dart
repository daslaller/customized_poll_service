/// repeat_engine.dart
///
/// Single entrypoint for consumers:
///
/// ```dart
/// import 'package:your_package_name/repeat_engine.dart';
///
/// final engine = AsyncRepeatEngine<int>(
///   name: 'example',
///   pollingInterval: Duration(milliseconds: 250),
///   onPoll: () async => 42,
/// );
/// ```
///
/// Re-exports:
/// - events.dart (PollEvent, PollEventType, PollStatus, PollError)
/// - AsyncSyncResultRepeatEngine (drop ticks while busy; “freshness”)
/// - AsyncRepeatEngine (queue ticks; sequential; “completeness”)
/// - AdvancedRepeatEngine / IsolateRepeatEngine (heavy work off main isolate)
library;

// Public API
export 'src/shared/events.dart'
    show PollEvent, PollEventType, PollStatus, PollError;

// Engines (keep only the public classes you want to expose)
export 'src/SyncRepeatEngine.dart'
    show AsyncSyncResultRepeatEngine;
export 'src/AsyncRepeatEngine.dart'
    show AsyncRepeatEngine;
export 'src/IsolateRepeatEngine.dart'
    show AdvancedRepeatEngine, OverflowStrategy;
