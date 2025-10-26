import 'dart:async';
import 'dart:developer';

import 'shared/events.dart';

class AsyncRepeatEngine<T> {
  final String name;
  final OnPollAction<T> onPoll;
  Duration pollingInterval;
  final bool enableErrorRecovery;
  final int? maxRetries;

  final _events = StreamController<PollEvent<T>>.broadcast();
  Stream<PollEvent<T>> get events => _events.stream;
  Stream<T> get dataStream =>
      events.where((e) => e.type == PollEventType.success && e.data != null).map((e) => e.data as T);

  bool _disposed = false;
  bool _paused = false;
  int _consecutiveErrors = 0;
  int pollCount = 0;
  DateTime? lastPollTime;
  DateTime? startTime;
  T? latestData;
  PollError? lastError;

  StreamSubscription<PollEvent<T>>? _sub;

  AsyncRepeatEngine({
    required this.name,
    required this.onPoll,
    this.pollingInterval = const Duration(seconds: 10),
    this.enableErrorRecovery = true,
    this.maxRetries = 3,
  }) {
    if (name.isEmpty) throw ArgumentError('Name cannot be empty');
    if (pollingInterval.inMilliseconds < 100) {
      throw ArgumentError('Polling interval must be at least 100ms');
    }
    if (maxRetries != null && maxRetries! < 0) {
      throw ArgumentError('Max retries must be non-negative');
    }
    _start();
  }

  void _start() {
    if (_disposed) return;
    startTime = DateTime.now();
    log(name: name, '$name started');
    _events.add(_life(PollEventType.started, metadata: {
      'pollingIntervalMs': pollingInterval.inMilliseconds,
    }));

    // Periodic ticks → asyncMap to sequentially process each tick
    final tickStream = Stream<int>.periodic(pollingInterval, (i) => i);

    _sub = tickStream
        .asyncMap<PollEvent<T>>((_) async {
      final started = DateTime.now();
      int attempt = 0;
      while (true) {
        try {
          final result = await onPoll(); // sequential per tick
          final dur = DateTime.now().difference(started);

          pollCount++;
          lastPollTime = started;
          latestData = result;
          _consecutiveErrors = 0;
          lastError = null;

          return _ok(result, started, dur);
        } catch (e, st) {
          attempt++;
          _consecutiveErrors++;
          lastError = PollError(e, st, DateTime.now());
          // emit error event per failure (optional)
          _events.add(_err(started));

          if (!enableErrorRecovery || (maxRetries != null && attempt > maxRetries!)) {
            log(name: name, 'Max retries exceeded for this tick (attempts=$attempt)');
            // Give up this tick; produce a no-op event so asyncMap completes
            return _life(PollEventType.error);
          }
          // backoff (capped roughly at 32x)
          final factor = attempt > 5 ? 32 : (1 << (attempt - 1));
          await Future.delayed(pollingInterval * factor);
        }
      }
    })
        .listen((evt) {
      if (_disposed) return;
      // Only forward success & lifecycle/error we generated
      if (evt.type == PollEventType.success || evt.type == PollEventType.error) {
        _events.add(evt);
      }
    });
  }

  PollEvent<T> _ok(T data, DateTime started, Duration dur) => PollEvent<T>(
    type: PollEventType.success,
    data: data,
    successfulPollCount: pollCount,
    timestamp: started,
    identifier: name,
    status: _paused ? PollStatus.paused : PollStatus.running,
    duration: dur,
  );

  PollEvent<T> _err(DateTime started) => PollEvent<T>(
    type: PollEventType.error,
    data: latestData,
    successfulPollCount: pollCount,
    timestamp: started,
    identifier: name,
    status: _paused ? PollStatus.paused : PollStatus.running,
    error: lastError,
  );

  PollEvent<T> _life(PollEventType t, {Map<String, dynamic>? metadata}) => PollEvent<T>(
    type: t,
    data: latestData,
    successfulPollCount: pollCount,
    timestamp: DateTime.now(),
    identifier: name,
    status: _paused ? PollStatus.paused : PollStatus.running,
    metadata: metadata,
  );

  void pause() {
    if (_disposed || _paused) return;
    _paused = true;
    _sub?.pause();
    _events.add(_life(PollEventType.paused));
  }

  void resume() {
    if (_disposed || !_paused) return;
    _paused = false;
    _sub?.resume();
    _events.add(_life(PollEventType.resumed));
  }

  void updatePollingInterval(Duration newInterval) {
    if (_disposed) return;
    if (newInterval.inMilliseconds < 100) {
      throw ArgumentError('Polling interval must be at least 100ms');
    }
    final old = pollingInterval;
    pollingInterval = newInterval;

    _sub?.cancel();
    _sub = null;
    _events.add(_life(PollEventType.intervalChanged, metadata: {
      'oldIntervalMs': old.inMilliseconds,
      'newIntervalMs': newInterval.inMilliseconds,
    }));
    _start();
  }

  void stop() {
    if (_disposed) return;
    _sub?.cancel();
    _sub = null;
    _events.add(_life(PollEventType.stopped));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stop();
    _events.add(_life(PollEventType.disposed));
    _events.close();
  }
}
