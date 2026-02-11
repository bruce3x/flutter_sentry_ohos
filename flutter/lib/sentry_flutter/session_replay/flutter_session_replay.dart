import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'platform_stub.dart' if (dart.library.io) 'platform_io.dart';

/// Collects Flutter frames for Sentry Session Replay on HarmonyOS.
///
/// This implementation uses a low-priority Scheduler (similar to Android)
/// to avoid blocking the UI thread during frame capture.
class FlutterSessionReplayRecorder with WidgetsBindingObserver {
  FlutterSessionReplayRecorder({
    required GlobalKey repaintBoundaryKey,
    Duration frameInterval = const Duration(milliseconds: 1000), // Default to 1s (1fps) to match Android and avoid aggressive throttling
    MethodChannel? channel,
  })  : _repaintBoundaryKey = repaintBoundaryKey,
        _frameInterval = frameInterval,
        _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'io.sentry.sessionReplay/native';

  static const double _maxPixelRatio = 0.2;
  static const Duration _slowCaptureThreshold = Duration(milliseconds: 120);
  static const Duration _slowCaptureCooldown = Duration(milliseconds: 600);
  static const Duration _scrollResumeDelay = Duration(milliseconds: 200);

  final GlobalKey _repaintBoundaryKey;
  Duration _frameInterval;
  final MethodChannel _channel;

  bool _isRunning = false;
  _Scheduler? _scheduler;
  int _capturedFrameCount = 0;
  int _sentFrameCount = 0;
  DateTime? _captureCooldownUntil;
  Duration _schedulerEpoch = Duration.zero;
  
  // Scroll detection (kept for potential future use but pausing logic is removed)
  bool _pointerRouteAttached = false;
  DateTime? _lastScrollEventTime;
  bool _isScrolling = false;
  Timer? _scrollResumeTimer;
  DateTime? _lastPointerMoveTime;
  int _recentPointerMoveCount = 0;

  ReceivePort? _frameWorkerReceivePort;
  StreamSubscription<dynamic>? _frameWorkerSubscription;
  SendPort? _frameWorkerSendPort;
  Isolate? _frameWorkerIsolate;
  Completer<void>? _frameWorkerReadyCompleter;

  /// Starts the recorder. No-op on unsupported platforms.
  /// Uses native screenshot in ArkTS layer.
  void start() {
    if (!isSupported) {
      return;
    }
    if (_isRunning) {
      return;
    }
    _isRunning = true;
    _capturedFrameCount = 0;
    _sentFrameCount = 0;
    _resetPointerMoveTracking();
    debugPrint(
      'FlutterSessionReplayRecorder start: using native screenshot in ArkTS layer',
    );
    WidgetsBinding.instance.addObserver(this);
    _attachPointerRoute();
    // Notify ArkTS layer to start native screenshot
    _notifyStartNativeScreenshot();
  }

  /// Stops capturing frames.
  void stop() {
    if (!_isRunning) {
      return;
    }
    _isRunning = false;
    debugPrint(
      'FlutterSessionReplayRecorder stop: captured=$_capturedFrameCount sent=$_sentFrameCount',
    );
    WidgetsBinding.instance.removeObserver(this);
    _detachPointerRoute();
    // Notify ArkTS layer to stop native screenshot
    _notifyStopNativeScreenshot();
  }

  bool get isRunning => _isRunning;

  Duration get frameInterval => _frameInterval;

  void updateFrameInterval(Duration value) {
    if (value <= Duration.zero) {
      return;
    }
    _frameInterval = value;
    if (_isRunning) {
      _restartScheduler();
    }
  }

  static bool get isSupported => !kIsWeb && platformIsOhos;

  @override
  void didHaveMemoryPressure() {
    stop();
  }

  Future<void> _restartScheduler() async {
    await _stopScheduler();
    if (!_isRunning) {
      return;
    }
    assert(_frameInterval.inMicroseconds > 0);
    _scheduler = _Scheduler(
      _frameInterval,
      _onScheduledCapture,
      (callback) {
        WidgetsBinding.instance
          ..ensureVisualUpdate()
          ..addPostFrameCallback(callback);
      },
    );
    _scheduler!.start();
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _stopScheduler() async {
    await _scheduler?.stop();
    _scheduler = null;
  }

  Future<void> _onScheduledCapture(Duration sinceSchedulerEpoch) async {
    // 新方案：不再在 Flutter 层捕获帧，改为在 ArkTS 层使用原生截图
    // 这里只保留滑动检测，用于通知 ArkTS 层暂停/恢复
    if (!_isRunning) {
      return;
    }
    // 滑动检测逻辑保留，用于通知 ArkTS 层
    // 不再调用 _captureFrame()
  }

  bool get _isCaptureCoolingDown {
    if (_captureCooldownUntil == null) {
      return false;
    }
    return DateTime.now().isBefore(_captureCooldownUntil!);
  }

  void _enterCaptureCooldown() {
    _captureCooldownUntil = DateTime.now().add(_slowCaptureCooldown);
  }

  Future<void> _captureFrame() async {
    // 在开始捕获前检查是否正在滑动
    if (_isScrolling) {
      return;
    }
    final stopwatch = Stopwatch()..start();
    await _ensureFrameWorkerReady();
    // 再次检查滑动状态（可能在 await 期间开始滑动）
    if (_isScrolling) {
      return;
    }
    final RenderRepaintBoundary? boundary =
        _repaintBoundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) {
      return;
    }
    
    if (boundary.debugNeedsPaint) {
      return;
    }
    
    try {
      final double pixelRatio =
          _clampPixelRatio(_devicePixelRatioFor(boundary));
      
      final toImageStart = stopwatch.elapsedMicroseconds;
      final ui.Image image = await boundary.toImage(pixelRatio: pixelRatio);
      // 检查滑动状态（toImage 可能耗时较长）
      if (_isScrolling) {
        image.dispose();
        return;
      }
      final toImageTime = stopwatch.elapsedMicroseconds - toImageStart;
      
      final int width = image.width;
      final int height = image.height;
      
      // 如果 toImage 花费超过阈值，则直接丢弃该帧，避免长时间阻塞
      if (toImageTime > _slowCaptureThreshold.inMicroseconds) {
        image.dispose();
        debugPrint(
          '[PERF] FlutterSessionReplayRecorder capture skipped: toImage slow (${(toImageTime / 1000).toStringAsFixed(1)}ms > ${_slowCaptureThreshold.inMilliseconds}ms)',
        );
        _enterCaptureCooldown();
        return;
      }
      
      final toByteDataStart = stopwatch.elapsedMicroseconds;
      final ByteData? byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      // 检查滑动状态（toByteData 可能耗时较长）
      if (_isScrolling) {
        image.dispose();
        return;
      }
      final toByteDataTime = stopwatch.elapsedMicroseconds - toByteDataStart;
      
      image.dispose();
      if (byteData == null) {
        return;
      }
      
      final int captureIndex = ++_capturedFrameCount;
      final totalTime = stopwatch.elapsedMicroseconds;
      stopwatch.stop();
      
      if (captureIndex % 10 == 1 || toImageTime > 50000 || totalTime > 100000) {
        debugPrint(
          '[PERF] FlutterSessionReplayRecorder capture #$captureIndex size=${width}x$height | '
          'toImage=${(toImageTime / 1000).toStringAsFixed(1)}ms toByteData=${(toByteDataTime / 1000).toStringAsFixed(1)}ms total=${(totalTime / 1000).toStringAsFixed(1)}ms',
        );
      }
      
      if (toImageTime > 80000 || totalTime > 150000) {
        _enterCaptureCooldown();
      }
      
      // 再次检查滑动状态，如果正在滑动则不发送
      if (_isScrolling) {
        return;
      }
      
      final byteDataList = byteData.buffer.asUint8List();
      try {
        final pixels = await compute(_processPixelData, _PixelDataInput(
          data: byteDataList,
          width: width,
          height: height,
        ));
        // 检查滑动状态，如果正在滑动则不发送
        if (!_isScrolling) {
          Future<void>.microtask(() {
            _sendFrameToWorker(
              pixels: pixels,
              width: width,
              height: height,
              pixelRatio: pixelRatio,
            );
          });
        }
      } catch (error, stackTrace) {
      debugPrint(
          'FlutterSessionReplayRecorder compute error: $error\n$stackTrace',
        );
        // 检查滑动状态，如果正在滑动则不发送
        if (!_isScrolling) {
          final pixels = Uint8List.fromList(byteDataList);
          Future<void>.microtask(() {
            _sendFrameToWorker(
              pixels: pixels,
        width: width,
        height: height,
        pixelRatio: pixelRatio,
      );
          });
        }
      }
    } catch (error, stackTrace) {
      stopwatch.stop();
      debugPrint('FlutterSessionReplayRecorder capture failed: $error\n$stackTrace');
    }
  }

  void _sendFrameToWorker({
    required Uint8List pixels,
    required int width,
    required int height,
    required double pixelRatio,
  }) {
    if (!_isRunning || _isScrolling) {
      return;
    }
    final sendPort = _frameWorkerSendPort;
    if (sendPort == null) {
      return;
    }
      final int timestampUs = DateTime.now().microsecondsSinceEpoch;
    sendPort.send({
      'type': 'frame',
      'frame': <String, Object?>{
        'pixels': pixels,
        'width': width,
        'height': height,
        'pixelRatio': pixelRatio,
        'timestamp': timestampUs,
      },
    });
  }

  Future<_BatchSendResult> _sendFrameBatch(
      List<Map<String, Object?>> frames) async {
    if (frames.isEmpty) {
      return const _BatchSendResult(success: false, channelTimeUs: 0);
    }
    // 如果正在滑动，立即返回，避免阻塞主线程
    if (_isScrolling) {
      return const _BatchSendResult(success: false, channelTimeUs: 0);
    }
    try {
      final stopwatch = Stopwatch()..start();
      await _channel.invokeMethod<void>('pushFrameBatch', <String, Object?>{
        'frames': frames,
      });
      // 在 await 之后再次检查滑动状态（可能在 await 期间开始滑动）
      if (_isScrolling) {
        stopwatch.stop();
        return const _BatchSendResult(success: false, channelTimeUs: 0);
      }
      final channelTime = stopwatch.elapsedMicroseconds;
      stopwatch.stop();
      _sentFrameCount += frames.length;
      if (_sentFrameCount % 20 == 0 || channelTime > 100000) {
      debugPrint(
          '[PERF] FlutterSessionReplayRecorder pushFrameBatch: count=${frames.length} channelTime=${channelTime}us',
      );
      }
      return _BatchSendResult(success: true, channelTimeUs: channelTime);
    } catch (error, stackTrace) {
      debugPrint(
        'FlutterSessionReplayRecorder pushFrameBatch failed: $error\n$stackTrace',
      );
      return const _BatchSendResult(success: false, channelTimeUs: 0);
    }
  }

  Future<void> _startFrameWorker() async {
    if (_frameWorkerReceivePort != null) {
      if (_frameWorkerReadyCompleter != null) {
        await _frameWorkerReadyCompleter!.future;
      }
      return;
    }
    _frameWorkerReceivePort = ReceivePort();
    _frameWorkerReadyCompleter = Completer<void>();
    _frameWorkerSubscription =
        _frameWorkerReceivePort!.listen((dynamic message) {
      if (_frameWorkerReadyCompleter != null &&
          !_frameWorkerReadyCompleter!.isCompleted &&
          message is SendPort) {
        _frameWorkerSendPort = message;
        _frameWorkerReadyCompleter!.complete();
        return;
      }
      _handleWorkerMessage(message);
    });
    _frameWorkerIsolate = await Isolate.spawn<_FrameWorkerInitMessage>(
      _frameWorkerEntry,
      _FrameWorkerInitMessage(
        mainSendPort: _frameWorkerReceivePort!.sendPort,
        flushIntervalMs: 120,
        maxBuffer: 2,
        slowPushThresholdMs: 150,
        slowPushCooldownMs: 350,
      ),
    );
    await _frameWorkerReadyCompleter!.future;
  }

  void _stopFrameWorker() {
    _frameWorkerSendPort?.send(const {'type': 'stop'});
    _frameWorkerSubscription?.cancel();
    _frameWorkerReceivePort?.close();
    _frameWorkerSubscription = null;
    _frameWorkerReceivePort = null;
    _frameWorkerSendPort = null;
    _frameWorkerReadyCompleter = null;
    _frameWorkerIsolate?.kill(priority: Isolate.immediate);
    _frameWorkerIsolate = null;
  }

  Future<void> _ensureFrameWorkerReady() async {
    if (_frameWorkerSendPort != null) {
      return;
    }
    await _startFrameWorker();
  }

  void _handleWorkerMessage(dynamic message) {
    if (message is! Map) {
      return;
    }
    final String? type = message['type'] as String?;
    if (type == 'batch') {
      final List<dynamic> rawFrames =
          message['frames'] as List<dynamic>? ?? <dynamic>[];
      final frames = rawFrames
          .map<Map<String, Object?>>(
              (dynamic item) => (item as Map).cast<String, Object?>())
          .toList();
      _processWorkerBatch(frames);
    }
  }

  Future<void> _processWorkerBatch(List<Map<String, Object?>> frames) async {
    if (frames.isEmpty || !_isRunning || _isScrolling) {
      // 如果正在滑动，丢弃这批帧，不发送 batchAck，让 worker 知道发送失败
      return;
    }
    final result = await _sendFrameBatch(frames);
    // 发送 batchAck 回 worker，告知发送结果
    // 如果正在滑动，不发送 ack，让 worker 知道发送失败
    if (!_isScrolling) {
      _frameWorkerSendPort?.send({
        'type': 'batchAck',
        'channelTimeUs': result.channelTimeUs,
      });
    }
  }

  double _devicePixelRatioFor(RenderRepaintBoundary boundary) {
    final BuildContext? context = _repaintBoundaryKey.currentContext;
    if (context != null) {
      final MediaQueryData? mediaQuery = MediaQuery.maybeOf(context);
      if (mediaQuery != null) {
        return mediaQuery.devicePixelRatio;
      }
    }
    // ignore: deprecated_member_use
    return WidgetsBinding.instance.window.devicePixelRatio;
  }

  double _clampPixelRatio(double ratio) {
    if (ratio <= 0) {
      return 1.0;
    }
    return math.min(ratio, _maxPixelRatio);
  }

  static Uint8List _processPixelData(_PixelDataInput input) {
    return Uint8List.fromList(input.data);
  }

  void _attachPointerRoute() {
    if (_pointerRouteAttached) {
      return;
    }
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handleGlobalPointerEvent);
    _pointerRouteAttached = true;
  }

  void _detachPointerRoute() {
    if (!_pointerRouteAttached) {
      return;
    }
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_handleGlobalPointerEvent);
    _pointerRouteAttached = false;
  }

  void _handleGlobalPointerEvent(PointerEvent event) {
    if (!_isRunning) {
      return;
    }
    if (event is PointerScrollEvent) {
      _recordScrollActivity();
      return;
    }
    if (event is PointerMoveEvent && event.down) {
      final ui.Offset delta = event.delta;
      final DateTime now = DateTime.now();
      
      // 滑动预测：如果短时间内有多次移动，提前检测滑动趋势
      if (_lastPointerMoveTime != null && 
          now.difference(_lastPointerMoveTime!) < const Duration(milliseconds: 50)) {
        _recentPointerMoveCount++;
      } else {
        _recentPointerMoveCount = 1;
      }
      _lastPointerMoveTime = now;
      
      // 降低阈值，更快检测滑动（从 0.5 降到 0.2）
      // 或者如果短时间内有多次移动，也认为是滑动
      if (delta.dx.abs() > 0.2 || delta.dy.abs() > 0.2 || _recentPointerMoveCount >= 3) {
        _recordScrollActivity();
      }
    }
  }

  void _recordScrollActivity() {
    _lastScrollEventTime = DateTime.now();
    // No-op: Removed pausing logic to match Android behavior
  }
  
  void _resetPointerMoveTracking() {
    _lastPointerMoveTime = null;
    _recentPointerMoveCount = 0;
  }

  void _attemptScrollResume() {
    // No-op: Removed resuming logic as we don't pause anymore
  }

  void _notifyScrollingState(bool isScrolling) {
    // No-op: Don't notify native side about scrolling state to avoid pausing
  }

  void _notifyStartNativeScreenshot() {
    try {
      _channel.invokeMethod<void>('startNativeScreenshot', <String, Object?>{
        'frameInterval': _frameInterval.inMilliseconds,
      });
    } catch (error) {
      debugPrint('[PERF] FlutterSessionReplayRecorder failed to notify start native screenshot: $error');
    }
  }

  void _notifyStopNativeScreenshot() {
    try {
      _channel.invokeMethod<void>('stopNativeScreenshot', <String, Object?>{});
    } catch (error) {
      debugPrint('[PERF] FlutterSessionReplayRecorder failed to notify stop native screenshot: $error');
    }
  }
}

/// Low-priority scheduler similar to Android implementation.
/// Waits for previous callback to finish before scheduling next one.
class _Scheduler {
  final Future<void> Function(Duration) _callback;
  final Duration _interval;
  final void Function(FrameCallback callback) _addPostFrameCallback;
  bool _running = false;
  Future<void>? _scheduled;
  Future<void>? _runningCallback;

  _Scheduler(this._interval, this._callback, this._addPostFrameCallback);

  void start() {
    _running = true;
    if (_scheduled == null) {
      _runAfterNextFrame();
    }
  }

  Future<void> stop() async {
    _running = false;
    final scheduled = _scheduled;
    _scheduled = null;
    if (scheduled != null) {
      await scheduled;
    }
  }

  void pause() {
    _running = false;
    _scheduled = null; // 取消任何待调度的任务
    // 不取消 _runningCallback，让当前捕获完成
  }

  void resume() {
    if (!_running) {
      _running = true;
      _runAfterNextFrame(); // 立即恢复调度
    }
  }

  @pragma('vm:prefer-inline')
  void _scheduleNext() {
    if (_running) {
      _scheduled ??= Future.delayed(_interval, _runAfterNextFrame);
    }
  }

  @pragma('vm:prefer-inline')
  void _runAfterNextFrame() {
    final runningCallback = _runningCallback ?? Future.value();
    runningCallback.whenComplete(() {
      _scheduled = null;
      if (_running) { // 只有在运行状态时才添加回调
        _addPostFrameCallback(_run);
      }
    });
  }

  void _run(Duration timestamp) {
    if (!_running) return;
    _runningCallback = _callback(timestamp);
    _scheduleNext();
  }
}

class _PixelDataInput {
  final Uint8List data;
  final int width;
  final int height;

  _PixelDataInput({
    required this.data,
    required this.width,
    required this.height,
  });
}

class _BatchSendResult {
  final bool success;
  final int channelTimeUs;
  const _BatchSendResult({
    required this.success,
    required this.channelTimeUs,
  });
}

class _FrameWorkerInitMessage {
  final SendPort mainSendPort;
  final int flushIntervalMs;
  final int maxBuffer;
  final int slowPushThresholdMs;
  final int slowPushCooldownMs;
  const _FrameWorkerInitMessage({
    required this.mainSendPort,
    required this.flushIntervalMs,
    required this.maxBuffer,
    required this.slowPushThresholdMs,
    required this.slowPushCooldownMs,
  });
}

void _frameWorkerEntry(_FrameWorkerInitMessage message) {
  final ReceivePort workerPort = ReceivePort();
  message.mainSendPort.send(workerPort.sendPort);
  final _FrameWorker worker = _FrameWorker(
    mainPort: message.mainSendPort,
    flushInterval: Duration(milliseconds: message.flushIntervalMs),
    maxBuffer: message.maxBuffer,
    slowPushThreshold: Duration(milliseconds: message.slowPushThresholdMs),
    slowPushCooldown: Duration(milliseconds: message.slowPushCooldownMs),
  );
  workerPort.listen((dynamic msg) {
    if (msg is Map) {
      worker.handleMessage(msg, workerPort);
    }
  });
}

class _FrameWorker {
  _FrameWorker({
    required this.mainPort,
    required this.flushInterval,
    required this.maxBuffer,
    required this.slowPushThreshold,
    required this.slowPushCooldown,
  });

  final SendPort mainPort;
  final Duration flushInterval;
  final int maxBuffer;
  final Duration slowPushThreshold;
  final Duration slowPushCooldown;

  final List<Map<String, Object?>> _pendingFrames = <Map<String, Object?>>[];
  Timer? _flushTimer;
  bool _awaitingAck = false;
  bool _paused = false; // Pause sending during scrolling
  int _batchCounter = 0;
  DateTime? _nextFlushAllowed;

  void handleMessage(Map<dynamic, dynamic> message, ReceivePort port) {
    final String? type = message['type'] as String?;
    switch (type) {
      case 'frame':
        final frame =
            (message['frame'] as Map).cast<String, Object?>();
        _pendingFrames.add(frame);
        if (_pendingFrames.length > maxBuffer) {
          _pendingFrames.removeAt(0);
        }
        if (!_paused) {
          _scheduleFlush();
        }
        break;
      case 'batchAck':
        _awaitingAck = false;
        final int channelTimeUs = message['channelTimeUs'] as int? ?? 0;
        if (channelTimeUs > slowPushThreshold.inMicroseconds) {
          _nextFlushAllowed = DateTime.now().add(slowPushCooldown);
        } else {
          _nextFlushAllowed = null;
        }
        if (!_paused) {
          _scheduleFlush();
        }
        break;
      case 'pause':
        _paused = true;
        _flushTimer?.cancel();
        _flushTimer = null;
        // 清空待发送队列，避免滑动结束后立即处理积压的帧
        _pendingFrames.clear();
        break;
      case 'resume':
        _paused = false;
        _scheduleFlush();
        break;
      case 'stop':
        _flushTimer?.cancel();
        _pendingFrames.clear();
        port.close();
        break;
      default:
        break;
    }
  }

  void _scheduleFlush() {
    if (_paused || _awaitingAck || _pendingFrames.isEmpty) {
      return;
    }
    if (_flushTimer != null) {
      return;
    }
    Duration delay = flushInterval;
    if (_nextFlushAllowed != null) {
      final Duration untilNext =
          _nextFlushAllowed!.difference(DateTime.now());
      if (untilNext > delay) {
        delay = untilNext;
      }
    }
    if (delay.isNegative) {
      delay = Duration.zero;
    }
    _flushTimer = Timer(delay, _flushPending);
  }

  void _flushPending() {
    _flushTimer = null;
    if (_paused || _awaitingAck || _pendingFrames.isEmpty) {
      if (!_paused) {
        _scheduleFlush();
      }
      return;
    }
    final frames = List<Map<String, Object?>>.from(_pendingFrames);
    _pendingFrames.clear();
    _awaitingAck = true;
    final int batchId = ++_batchCounter;
    mainPort.send({
      'type': 'batch',
      'batchId': batchId,
      'frames': frames,
    });
  }
}
