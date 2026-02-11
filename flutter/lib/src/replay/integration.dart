import 'dart:async';
import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../../sentry_flutter.dart';
import '../event_processor/replay_event_processor.dart';
import '../native/sentry_native_binding.dart';
import 'replay_config.dart';

@internal
const replayIntegrationName = 'ReplayIntegration';

@internal
class ReplayIntegration extends Integration<SentryFlutterOptions> {
  final SentryNativeBinding _native;

  ReplayIntegration(this._native);

  Hub? _hub;
  SentryFlutterOptions? _options;

  @override
  FutureOr<void> call(Hub hub, SentryFlutterOptions options) {
    final replayOptions = options.replay;
    if (_native.supportsReplay && replayOptions.isEnabled) {
      options.sdk.addIntegration(replayIntegrationName);
      _hub = hub;
      _options = options;

      // We only need the integration when error-replay capture is enabled.
      if ((replayOptions.onErrorSampleRate ?? 0) > 0) {
        options.addEventProcessor(ReplayEventProcessor(hub, _native));
      }

      SentryScreenshotWidget.onBuild((status, prevStatus) {
        // Skip config update if the difference is negligible (e.g., due to floating-point precision)
        // e.g a size.height of 200.00001 and 200.001 could be treated as equals
        if (prevStatus != null && status.matches(prevStatus)) {
          return true;
        }

        final resolution = _scaledResolution(
          status.size?.width ?? 0.0,
          status.size?.height ?? 0.0,
          replayOptions.quality.resolutionScalingFactor,
        );
        _native.setReplayConfig(ReplayConfig(
          windowWidth: status.size?.width ?? 0.0,
          windowHeight: status.size?.height ?? 0.0,
          width: resolution.width,
          height: resolution.height,
          frameRate: 1,
        ));

        return true;
      });
    }
  }

  Future<void> captureReplay() async {
    if (_native.supportsReplay && _options?.replay.isEnabled == true) {
      final replayId = await _native.captureReplay();
      _hub?.configureScope((scope) {
        // ignore: invalid_use_of_internal_member
        scope.replayId = replayId;
      });
    }
  }

  _ReplayResolution _scaledResolution(
      double width, double height, double scaleFactor) {
    if (width <= 0 || height <= 0) {
      return const _ReplayResolution(0, 0);
    }

    double targetWidth = width * scaleFactor;
    double targetHeight = height * scaleFactor;

    const double maxLongEdge = 1280.0;
    const double maxShortEdge = 720.0;

    final bool isLandscape = targetWidth >= targetHeight;
    double longEdge = isLandscape ? targetWidth : targetHeight;
    double shortEdge = isLandscape ? targetHeight : targetWidth;

    double ratio = 1.0;
    if (longEdge > maxLongEdge) {
      ratio = math.min(ratio, maxLongEdge / longEdge);
    }
    if (shortEdge * ratio > maxShortEdge) {
      ratio = math.min(ratio, maxShortEdge / shortEdge);
    }

    targetWidth *= ratio;
    targetHeight *= ratio;

    return _ReplayResolution(targetWidth, targetHeight);
  }
}

class _ReplayResolution {
  final double width;
  final double height;
  const _ReplayResolution(this.width, this.height);
}
