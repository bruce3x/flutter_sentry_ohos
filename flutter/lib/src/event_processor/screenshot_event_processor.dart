import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import '../../sentry_flutter.dart';
import '../screenshot/recorder.dart';
import '../screenshot/recorder_config.dart';

import '../screenshot/screenshot_support.dart';
import '../utils/debouncer.dart';

class ScreenshotEventProcessor implements EventProcessor {
  final SentryFlutterOptions _options;

  late final ScreenshotRecorder _recorder;
  late final Debouncer _debouncer;

  ScreenshotEventProcessor(this._options) {
    final targetResolution = _options.screenshotQuality.targetResolution();
    _recorder = ScreenshotRecorder(_options,
        config: ScreenshotRecorderConfig(
          width: targetResolution,
          height: targetResolution,
        ));
    _debouncer = Debouncer(
      // ignore: invalid_use_of_internal_member
      _options.clock,
      waitTime: Duration(milliseconds: 2000),
    );
  }

  @override
  Future<SentryEvent?> apply(SentryEvent event, Hint hint) async {
    if (event is SentryTransaction) {
      return event;
    }

    if (event.exceptions == null &&
        event.throwable == null &&
        SentryScreenshotWidget.isMounted) {
      return event;
    }

    if (event.type == 'feedback') {
      return event; // No need to attach screenshot of feedback form.
    }

    // 仍允许 Flutter 层截图（与 Android 对齐），OHOS 将依赖 PNG 修正确保有效

    final renderer = _options.rendererWrapper.renderer;
    if (!_options.isScreenshotSupported) {
      _options.log(
        SentryLevel.debug,
        'Screenshot: not supported in this environment with renderer $renderer',
      );
      return event;
    }

    // skip capturing in case of debouncing (=too many frequent capture requests)
    // the BeforeCaptureCallback may overrule the debouncing decision
    final shouldDebounce = _debouncer.shouldDebounce();
    final beforeCaptureScreenshot = _options.beforeCaptureScreenshot;

    try {
      FutureOr<bool>? result;

      if (beforeCaptureScreenshot != null) {
        result = beforeCaptureScreenshot(event, hint, shouldDebounce);
      }

      bool takeScreenshot = true;

      if (result != null) {
        if (result is Future<bool>) {
          takeScreenshot = await result;
        } else {
          takeScreenshot = result;
        }
      } else if (shouldDebounce) {
        _options.log(
          SentryLevel.debug,
          'Screenshot: skipping capture due to debouncing (too many captures within ${_debouncer.waitTime.inMilliseconds}ms)',
        );
        takeScreenshot = false;
      }

      if (!takeScreenshot) {
        return event;
      }
    } catch (exception, stackTrace) {
      _options.log(
        SentryLevel.error,
        'Screenshot: the beforeCaptureScreenshot/beforeScreenshot callback threw an exception',
        exception: exception,
        stackTrace: stackTrace,
      );
      if (_options.automatedTestMode) {
        rethrow;
      }
    }

    final screenshotData = await createScreenshot();
    if (screenshotData != null) {
      // 调整 PNG 头/IHDR 长度/宽高高位，避免少见环境下出现 0x20 空格字节
      _fixPngHeaderInPlace(screenshotData);
      // 与 Android 对齐：采用默认 event.attachment
      hint.screenshot = SentryAttachment.fromUint8List(
        screenshotData,
        'screenshot.png',
        contentType: 'image/png',
        // 使用默认类型，等价于不传；明确写上以便可读性
        attachmentType: SentryAttachment.typeAttachmentDefault,
      );
    }

    return event;
  }

  void _fixPngHeaderInPlace(Uint8List bytes) {
    try {
      if (bytes.length < 24) return;
      final sigOk = bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 && bytes[4] == 0x0D && bytes[5] == 0x0A && bytes[6] == 0x1A && bytes[7] == 0x0A;
      final ihdr = bytes[12] == 0x49 && bytes[13] == 0x48 && bytes[14] == 0x44 && bytes[15] == 0x52;
      if (!sigOk || !ihdr) return;
      // IHDR length
      if (bytes[8] == 0x20 || bytes[9] == 0x20 || bytes[10] == 0x20) {
        bytes[8] = 0x00; bytes[9] = 0x00; bytes[10] = 0x00; bytes[11] = 0x0D;
      }
      // width/height high-bytes
      if (bytes[16] == 0x20) bytes[16] = 0x00;
      if (bytes[17] == 0x20) bytes[17] = 0x00;
      if (bytes[20] == 0x20) bytes[20] = 0x00;
      if (bytes[21] == 0x20) bytes[21] = 0x00;
    } catch (_) {}
  }

  @internal
  Future<Uint8List?> createScreenshot() => _recorder.capture(
      (screenshot) => screenshot.pngData.then((v) => v.buffer.asUint8List()));
}
