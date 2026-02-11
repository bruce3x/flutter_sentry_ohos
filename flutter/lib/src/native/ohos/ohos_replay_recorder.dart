import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';

import '../../../sentry_flutter.dart';
import '../../replay/scheduled_recorder.dart';
import '../../replay/scheduled_recorder_config.dart';
import '../../screenshot/screenshot.dart';
import '../../screenshot/sentry_screenshot_widget.dart';
import '../../../sentry_flutter/session_replay/flutter_session_replay.dart';

/// HarmonyOS implementation of the scheduled screenshot replay recorder.
///
/// Unlike Android (JNI + Bitmap), OHOS uses the ETS layer to perform the
/// actual replay capture. This recorder focuses on capturing screenshots on
/// a schedule and passing them to the native side through the existing
/// MethodChannel handled by ETS (`SentryFlutterPlugin.ets`).
@internal
class OhosReplayRecorder extends ScheduledScreenshotRecorder {
  @internal // visible for testing, used by SentryNativeOhos
  static OhosReplayRecorder Function(SentryFlutterOptions) factory =
      OhosReplayRecorder.new;

  OhosReplayRecorder(super.options) {
    super.callback = _addReplayScreenshot;
  }

  final MethodChannel _frameChannel =
      const MethodChannel(FlutterSessionReplayRecorder.channelName);

  FlutterSessionReplayRecorder? _flutterRecorder;
  bool _isRunning = false;

  bool get _useFlutterRecorder => FlutterSessionReplayRecorder.isSupported;

  Duration get _configuredFrameInterval {
    final frameRate = config.frameRate;
    if (frameRate <= 0) {
      return const Duration(milliseconds: 250);
    }
    final milliseconds = (1000 / frameRate).round();
    return Duration(milliseconds: milliseconds);
  }

  void _ensureFlutterRecorder() {
    if (!_useFlutterRecorder) {
      return;
    }
    final recorder = _flutterRecorder;
    if (recorder == null) {
      _flutterRecorder = FlutterSessionReplayRecorder(
        repaintBoundaryKey: sentryScreenshotWidgetGlobalKey,
        frameInterval: _configuredFrameInterval,
        channel: _frameChannel,
      );
    } else {
      recorder.updateFrameInterval(_configuredFrameInterval);
    }
  }

  @override
  Future<void> start() async {
    _isRunning = true;
    if (_useFlutterRecorder) {
      _ensureFlutterRecorder();
      _flutterRecorder?.start();
      return;
    }
    await super.start();
  }

  @override
  Future<void> stop() async {
    _isRunning = false;
    if (_useFlutterRecorder) {
      _flutterRecorder?.stop();
      return;
    }
    await super.stop();
  }

  @override
  Future<void> pause() async {
    if (_useFlutterRecorder) {
      _flutterRecorder?.stop();
      _isRunning = false;
      return;
    }
    _isRunning = false;
    await super.pause();
  }

  @override
  Future<void> resume() async {
    if (_useFlutterRecorder) {
      _ensureFlutterRecorder();
      _isRunning = true;
      _flutterRecorder?.start();
      return;
    }
    _isRunning = true;
    await super.resume();
  }

  @override
  Future<void> onConfigurationChanged(
      ScheduledScreenshotRecorderConfig config) async {
    await super.onConfigurationChanged(config);
    if (_useFlutterRecorder) {
      final wasRunning = _isRunning;
      _flutterRecorder?.stop();
      _ensureFlutterRecorder();
      if (wasRunning) {
        _flutterRecorder?.start();
      }
      _isRunning = wasRunning;
    }
  }

  Future<void> _addReplayScreenshot(
      Screenshot screenshot, bool isNewlyCaptured) async {
    if (_useFlutterRecorder) {
      return;
    }
    final timestamp = screenshot.timestamp.millisecondsSinceEpoch;

    try {
      // Convert RGBA buffer into a byte list; ETS/native side will handle
      // encoding/aggregation as appropriate.
      final data = await screenshot.rawRgbaData;
      final bytes = data.buffer.asUint8List();

      options.log(
        SentryLevel.debug,
        '$logName: captured screenshot ('
        '${screenshot.width}x${screenshot.height} pixels, '
        '${bytes.lengthInBytes} bytes, ts=$timestamp)',
      );
      await _forwardFrame(bytes, screenshot.width, screenshot.height, timestamp);
    } catch (error, stackTrace) {
      options.log(
        SentryLevel.error,
        '$logName: OHOS replay screenshot processing failed',
        exception: error,
        stackTrace: stackTrace,
      );
      if (options.automatedTestMode) {
        rethrow;
      }
    }
  }

  Future<void> _forwardFrame(
    Uint8List pixels,
    int width,
    int height,
    int timestamp,
  ) async {
    try {
      final stride = width * 4;
      final payload = <String, Object?>{
        'pixels': pixels,
        'width': width,
        'height': height,
        'stride': stride,
        'timestamp': timestamp,
        'pixelRatio': 1.0,
      };
      try {
        await _frameChannel.invokeMethod<void>('pushFrameBatch', {
          'frames': [payload],
      });
      } on PlatformException catch (_) {
        await _frameChannel.invokeMethod<void>('pushFrame', payload);
      }
    } on PlatformException catch (exception, stackTrace) {
      options.log(
        SentryLevel.error,
        '$logName: pushFrame failed (${exception.message})',
        stackTrace: stackTrace,
      );
    } catch (error, stackTrace) {
      options.log(
        SentryLevel.error,
        '$logName: pushFrame unexpected error',
        exception: error,
        stackTrace: stackTrace,
      );
    }
  }
}


