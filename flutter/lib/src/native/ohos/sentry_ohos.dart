import 'dart:async';

import 'package:meta/meta.dart';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/services.dart';

import '../../../sentry_flutter.dart';
import '../sentry_native_channel.dart';
import '../../file_system_transport.dart';
import '../../replay/scheduled_recorder_config.dart';
import 'ohos_replay_recorder.dart';

/// OHOS specific native binding.
/// Currently reuses the generic MethodChannel implementation but
/// allows platform specific capability flags.
@internal
class SentryNativeOhos extends SentryNativeChannel {
  OhosReplayRecorder? _replayRecorder;
  SentryNativeOhos(super.options);
  static bool _didWarmup = false;

  @override
  bool get supportsReplay => true;

  @override
  Future<void> captureEnvelope(
      Uint8List envelopeData, bool containsUnhandledException) async {
    try {
      // 首选与 Android 一致的 bytes 传输
      // final asList = envelopeData.toList(growable: false);
      await channel.invokeMethod('captureEnvelope', [envelopeData, containsUnhandledException]);
      return;
    } on PlatformException catch (_) {
      // 回退到路径交接，规避通道可能的载荷上限
    } catch (_) {
      // 其它异常同样回退
      // ignore: avoid_print
      print('ohos captureEnvelope: unexpected error on bytes, fallback to file');
    }

    // use file handoff on OHOS to avoid large payload serialization limits
    // Fallback: write envelope to a temp file and pass the path
    final dir = Directory.systemTemp.createTempSync('sentry_env_ohos_');
    final file = File('${dir.path}/env_${DateTime.now().microsecondsSinceEpoch}.envelope');
    await file.writeAsBytes(envelopeData, flush: true);
    try {
      await channel.invokeMethod('captureEnvelopeFromPath', <String, dynamic>{
        'path': file.path,
        'containsUnhandled': containsUnhandledException,
      });
    } finally {
      try { if (file.existsSync()) file.deleteSync(); } catch (_) {}
      try { if (dir.existsSync()) dir.deleteSync(recursive: true); } catch (_) {}
    }
  }

  @override
  Future<void> init(Hub hub) async {
    await super.init(hub);
    if (options.experimental.replay.isEnabled) {
      channel.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'ReplayRecorder.start':
            final replayId =
            SentryId.fromId(call.arguments['replayId'] as String);

            final config = ScheduledScreenshotRecorderConfig(
                width: (call.arguments['width'] as num).toDouble(),
                height: (call.arguments['height'] as num).toDouble(),
                frameRate: call.arguments['frameRate'] as int);

            _replayRecorder = OhosReplayRecorder(
                config, options, channel, call.arguments['directory'] as String)
              ..start();

            hub.configureScope((s) {
              // ignore: invalid_use_of_internal_member
              s.replayId = replayId;
            });
            break;
          case 'ReplayRecorder.stop':
            hub.configureScope((s) {
              // ignore: invalid_use_of_internal_member
              s.replayId = null;
            });

            final future = _replayRecorder?.stop();
            _replayRecorder = null;
            await future;

            break;
          case 'ReplayRecorder.pause':
            await _replayRecorder?.pause();
            break;
          case 'ReplayRecorder.resume':
            await _replayRecorder?.resume();
            break;
          default:
            throw UnimplementedError('Method ${call.method} not implemented');
        }
      });
    }
    // 与 Android 保持一致：不主动拉取/设置 contexts，交由 SDK 链路在首次事件时机处理
    // 触发一次极轻事件，确保 envelope 管道预热，并让 LoadContextsIntegration 调用原生 loadContexts
    // 与 Android 冷启动能观测到 loadContexts/captureEnvelope 的行为对齐
    if (!_didWarmup) {
      // 推迟到下一个 microtask，确保所有 integrations（含 LoadContextsIntegration）已注册
      scheduleMicrotask(() async {
        try {
          await hub.captureMessage('sentry_ohos_warmup');
        } catch (_) {}
      });
      _didWarmup = true;
    }
  }
}
