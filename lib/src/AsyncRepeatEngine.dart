import 'dart:async';
import 'shared/events.dart';

class AsyncRepeatEngine<T> {
  final String name;
  final Future<T> Function() onPoll;
  Duration pollingInterval;

  final _events = StreamController<PollEvent<T>>.broadcast();
  Stream<PollEvent<T>> get events => _events.stream;
  Stream<T> get dataStream =>
      _events.stream.where((e) => e.type == PollEventType.success && e.data != null).map((e) => e.data as T);

  StreamSubscription<PollEvent<T>>? _sub;
  int _successCount = 0;

  AsyncRepeatEngine({
    required this.name,
    required this.onPoll,
    this.pollingInterval = const Duration(seconds: 1),
  }) {
    _start();
  }

  void _start() {
    _sub = Stream<void>.periodic(pollingInterval)
        .asyncMap<PollEvent<T>>((_) async {
      final t0 = DateTime.now();
      try {
        final data = await onPoll(); // queues if slow
        _successCount++;
        return PollEvent<T>(
          type: PollEventType.success,
          data: data,
          successfulPollCount: _successCount,
          timestamp: t0,
          identifier: name,
          status: PollStatus.running,
          duration: DateTime.now().difference(t0),
        );
      } catch (e, st) {
        return PollEvent<T>(
          type: PollEventType.error,
          successfulPollCount: _successCount,
          timestamp: DateTime.now(),
          identifier: name,
          status: PollStatus.running,
          error: PollError(e, st, DateTime.now()),
        );
      }
    })
        .listen(_events.add);
  }

  void pause()  => _sub?.pause();
  void resume() => _sub?.resume();
  void updatePollingInterval(Duration d) { _sub?.cancel(); pollingInterval = d; _start(); }
  void dispose() { _sub?.cancel(); _events.close(); }
}
