import 'dart:async';
import 'dart:developer';

/// Enhanced RepeatEngine with improved error handling, type safety, and performance
class RepeatEngine<T> {
  // Core configuration
  final String name;
  final FutureOr<T> Function() onPoll;
  Duration pollingInterval;
  final bool runUntilDisposed;
  final bool enableErrorRecovery;
  final int? maxRetries;
  
  // Internal state
  Timer? _timer;
  final _eventController = StreamController<PollEvent<T>>.broadcast();
  Completer<void>? _keepAliveCompleter;
  bool _isDisposed = false;
  
  // Public state (read-only)
  int pollCount = 0;
  DateTime? lastPollTime;
  DateTime? startTime;
  bool isPaused = false;
  DateTime? pauseStartTime;
  Duration totalPauseDuration = Duration.zero;
  T? latestData;
  PollError? lastError;
  int consecutiveErrors = 0;
  
  // Performance optimization
  late final int _pollingIntervalMs;
  
  RepeatEngine({
    required this.name,
    required this.onPoll,
    this.pollingInterval = const Duration(seconds: 10),
    this.runUntilDisposed = true,
    this.enableErrorRecovery = true,
    this.maxRetries = 3,
  }) : _pollingIntervalMs = pollingInterval.inMilliseconds {
    _validateConfiguration();
    _initialize();
  }
  
  void _validateConfiguration() {
    if (name.isEmpty) throw ArgumentError('Name cannot be empty');
    if (pollingInterval.inMilliseconds < 100) {
      throw ArgumentError('Polling interval must be at least 100ms');
    }
    if (maxRetries != null && maxRetries! < 0) {
      throw ArgumentError('Max retries must be non-negative');
    }
  }
  
  void _initialize() {
    startTime = DateTime.now();
    _startMonitoring();
    if (runUntilDisposed) {
      _keepAliveCompleter = Completer<void>();
    }
  }
  
  // Public API
  Stream<PollEvent<T>> get events => _eventController.stream;
  bool get isRunning => !(_timer == null || !_timer!.isActive);
  bool get isDisposed => _isDisposed;
  Duration? get uptime => startTime != null ? DateTime.now().difference(startTime!) : null;
  Duration get currentPauseDuration => 
      isPaused && pauseStartTime != null 
          ? DateTime.now().difference(pauseStartTime!) 
          : Duration.zero;
  
  // Helper method to emit lifecycle events
  void _emitLifecycleEvent(PollEventType type, {Map<String, dynamic>? metadata}) {
    if (_isDisposed || _eventController.isClosed) return;
    
    // Cache the status check and timestamp
    final currentStatus = isPaused ? PollStatus.paused : PollStatus.running;
    final eventTime = DateTime.now();
    
    _eventController.add(PollEvent<T>(
      type: type,
      data: latestData,
      pollCount: pollCount,
      timestamp: eventTime,
      identifier: name,
      status: currentStatus,
      metadata: metadata,
    ));
  }
  
  void _startMonitoring() {
    if (_isDisposed) return;
    
    log(name: name, '$name started');
    if (isRunning) _stopMonitoring();
    
    _timer = Timer.periodic(pollingInterval, (_) => _executePoll());
    _emitLifecycleEvent(PollEventType.started, metadata: {
      'pollingInterval': pollingInterval.inMilliseconds,
    });
  }
  
  Future<void> _executePoll() async {
    if (_isDisposed || _eventController.isClosed || isPaused) return;
    
    try {
      final startTime = DateTime.now();
      final data = await onPoll();
      final duration = DateTime.now().difference(startTime);
      
      // Update state
      pollCount++;
      lastPollTime = startTime;
      latestData = data;
      consecutiveErrors = 0;
      lastError = null;
      
      // Emit event - cache the status check
      if (!_eventController.isClosed) {
        final currentStatus = isPaused ? PollStatus.paused : PollStatus.running;
        _eventController.add(PollEvent<T>(
          type: PollEventType.success,
          data: data,
          pollCount: pollCount,
          timestamp: startTime,
          identifier: name,
          status: currentStatus,
          duration: duration,
        ));
      }
    } catch (error, stackTrace) {
      await _handleError(error, stackTrace);
    }
  }
  
  Future<void> _handleError(dynamic error, StackTrace stackTrace) async {
    consecutiveErrors++;
    lastError = PollError(error, stackTrace, DateTime.now());
    
    log(name: name, 'Poll error #$consecutiveErrors: $error');
    
    // Emit error event - cache the status check and timestamp
    if (!_eventController.isClosed) {
      final currentStatus = isPaused ? PollStatus.paused : PollStatus.running;
      final errorTime = DateTime.now();
      _eventController.add(PollEvent<T>(
        type: PollEventType.error,
        data: latestData,
        pollCount: pollCount,
        timestamp: errorTime,
        identifier: name,
        status: currentStatus,
        error: lastError,
      ));
    }
    
    // Handle error recovery
    if (enableErrorRecovery && 
        (maxRetries == null || consecutiveErrors <= maxRetries!)) {
      // Exponential backoff for retries
      final backoffMs = _pollingIntervalMs * (1 << (consecutiveErrors - 1).clamp(0, 5));
      await Future.delayed(Duration(milliseconds: backoffMs));
    } else {
      log(name: name, 'Max retries exceeded, stopping service');
      _stopMonitoring();
    }
  }
  
  void _stopMonitoring() {
    log(name: name, '$name stopped');
    _timer?.cancel();
    _timer = null;
    _emitLifecycleEvent(PollEventType.stopped);
  }
  
  void pause() {
    if (!isPaused && !_isDisposed) {
      isPaused = true;
      pauseStartTime = DateTime.now();
      log(name: name, '$name paused');
      _emitLifecycleEvent(PollEventType.paused, metadata: {
        'pauseStartTime': pauseStartTime!.toIso8601String(),
      });
    }
  }
  
  void resume() {
    if (isPaused && !_isDisposed) {
      final pauseDuration = pauseStartTime != null 
          ? DateTime.now().difference(pauseStartTime!) 
          : Duration.zero;
      
      isPaused = false;
      if (pauseStartTime != null) {
        totalPauseDuration += pauseDuration;
      }
      pauseStartTime = null;
      log(name: name, '$name resumed');
      _emitLifecycleEvent(PollEventType.resumed, metadata: {
        'pauseDuration': pauseDuration.inMilliseconds,
        'totalPauseDuration': totalPauseDuration.inMilliseconds,
      });
    }
  }
  
  void reset() {
    if (_isDisposed) return;
    
    final oldStats = {
      'oldPollCount': pollCount,
      'oldUptime': uptime?.inSeconds,
      'oldTotalPauseDuration': totalPauseDuration.inSeconds,
    };
    
    pollCount = 0;
    lastPollTime = null;
    startTime = DateTime.now();
    totalPauseDuration = Duration.zero;
    pauseStartTime = null;
    isPaused = false;
    consecutiveErrors = 0;
    lastError = null;
    log(name: name, '$name reset');
    _emitLifecycleEvent(PollEventType.reset, metadata: oldStats);
  }
  
  void updatePollingInterval(Duration newInterval) {
    if (_isDisposed) return;
    if (newInterval.inMilliseconds < 100) {
      throw ArgumentError('Polling interval must be at least 100ms');
    }
    
    final oldInterval = pollingInterval;
    pollingInterval = newInterval;
    
    if (isRunning) {
      _stopMonitoring();
      _startMonitoring();
    }
    
    _emitLifecycleEvent(PollEventType.intervalChanged, metadata: {
      'oldInterval': oldInterval.inMilliseconds,
      'newInterval': newInterval.inMilliseconds,
    });
  }
  
  Map<String, dynamic> getStats() {
    return {
      'name': name,
      'pollCount': pollCount,
      'isRunning': isRunning,
      'isPaused': isPaused,
      'isDisposed': _isDisposed,
      'startTime': startTime?.toIso8601String(),
      'lastPollTime': lastPollTime?.toIso8601String(),
      'uptime': uptime?.inSeconds,
      'totalPauseDuration': totalPauseDuration.inSeconds,
      'currentPauseDuration': currentPauseDuration.inSeconds,
      'latestData': latestData,
      'consecutiveErrors': consecutiveErrors,
      'lastError': lastError?.toString(),
    };
  }
  
  void dispose() {
    if (_isDisposed) return;
    
    _isDisposed = true;
    log(name: name, '$name disposed');
    _stopMonitoring();
    
    // Emit disposed event before closing the stream
    _emitLifecycleEvent(PollEventType.disposed, metadata: {
      'finalStats': getStats(),
    });
    
    _eventController.close();
    
    if (runUntilDisposed && 
        _keepAliveCompleter != null && 
        !_keepAliveCompleter!.isCompleted) {
      _keepAliveCompleter!.complete();
    }
  }
  
  Future<void> get keepAlive => _keepAliveCompleter?.future ?? Future.value();
}

// Supporting classes
enum PollEventType { 
  success, 
  error, 
  started, 
  stopped, 
  paused, 
  resumed, 
  reset, 
  disposed,
  intervalChanged 
}
enum PollStatus { running, paused, stopped }

class PollEvent<T> {
  final PollEventType type;
  final T? data;
  final int pollCount;
  final DateTime timestamp;
  final String identifier;
  final PollStatus status;
  final Duration? duration;
  final PollError? error;
  final Map<String, dynamic>? metadata;
  
  PollEvent({
    required this.type,
    this.data,
    required this.pollCount,
    required this.timestamp,
    required this.identifier,
    required this.status,
    this.duration,
    this.error,
    this.metadata,
  });
  
  @override
  String toString() => 'PollEvent($type, pollCount: $pollCount, data: $data)';
}

class PollError {
  final dynamic error;
  final StackTrace stackTrace;
  final DateTime timestamp;
  
  PollError(this.error, this.stackTrace, this.timestamp);
  
  @override
  String toString() => 'PollError($error at $timestamp)';
}