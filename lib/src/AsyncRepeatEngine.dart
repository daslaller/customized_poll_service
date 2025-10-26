import 'dart:async';
import 'shared/events.dart';

class AsyncRepeatEngine<T> {
  final String name;
  final Future<T> Function() onPoll;
  Duration pollingInterval;

  final _events = StreamController<PollEvent<T>>.broadcast();
  final _lifeCycleEvents = StreamController<LifeCycle>.broadcast();
  Stream<PollEvent<T>> get events => _events.stream;
  Stream get cycleEvents => _lifeCycleEvents.stream;
  Stream<T> get dataStream => events
      .where((e) => e.type == PollEventType.success && e.data != null)
      .map((e) => e.data as T);

  StreamSubscription<PollEvent<T>>? _sub;
  int _successCount = 0;

  AsyncRepeatEngine({
    required this.name,
    required this.onPoll,
    this.pollingInterval = const Duration(seconds: 1),
  }) {
    _events
      ..onCancel = () {
        _lifeCycleEvents.add(LifeCycle.cancel);
      }
      ..onListen = () {
        _lifeCycleEvents.add(LifeCycle.listen);
      }
      ..stream.listen((data) => _lifeCycleEvents.add(LifeCycle.data));
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
        .listen(
          (data) {
            _events.add(data);
            _lifeCycleEvents.add(LifeCycle.data);
          },
          onDone: () => _lifeCycleEvents.add(LifeCycle.done),
          onError: (e, st) => _lifeCycleEvents.add(LifeCycle.error),
        );
  }

  void pause() {
    _lifeCycleEvents.add(LifeCycle.pause);
    _sub?.pause();
  }

  void resume() {
    _lifeCycleEvents.add(LifeCycle.resume);
    _sub?.resume();
  }

  void dispose() {
    _lifeCycleEvents.add(LifeCycle.disposed);
    _sub?.cancel();
    _events.close();
    _lifeCycleEvents.close();
  }

  void updatePollingInterval(Duration d) {
    _sub?.cancel();
    pollingInterval = d;
    _start();
  }
}
