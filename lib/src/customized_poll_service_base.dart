import 'dart:async';
import 'dart:developer';

class RepeatEnginer<T> {
  late Timer? _timer;
  final _eventController =
      StreamController<Map<T, dynamic>>.broadcast();
  final Duration exemptionDuration, pollingInterval;

 Stream<Map<T, dynamic>> get events => _eventController.stream;
 bool get isRunning =>
      !(_timer == null || !_timer!.isActive); 
      
  TelavoxMonitor({
    this.exemptionDuration = const Duration(minutes: 5),
    this.pollingInterval = const Duration(seconds: 10),
  });

  void startMonitoring() {
    log(name: 'TelavoxMonitor', 'TelavoxMonitor started');
    if (isRunning) stopMonitoring();
    _timer = Timer.periodic(
      pollingInterval,
      (_) => onPoll(),
    ); // Initialize timer
  }

  void stopMonitoring() {
    log(name: 'TelavoxMonitor', 'TelavoxMonitor stopped');
    _timer?.cancel();
  }

  void onPoll() {
    log(name: 'TelavoxMonitor', 'TelavoxMonitor polled');
    _eventController.add({});
  }

  void dispose() {
    _eventController.close();
  }
}