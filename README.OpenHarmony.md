<p align="center">
  <h1 align="center"> <code>sentry_flutter</code> </h1>
</p>

This project is based on [sentry_flutter](https://pub.dev/packages/sentry_flutter) and has been adapted for the OpenHarmony platform.

## 1. Installation & Usage

### 1.1 Installation

Navigate to your project directory and add the following dependency to pubspec.yaml:

<!-- tabs:start -->

#### pubspec.yaml

```yaml
...

dependencies:
  sentry_flutter:
    git:
      url: https://gitcode.com/OpenHarmony-Flutter/fluttertpc_sentry-dart
      path: flutter
      ref: br_3.35

dependency_overrides:
  sentry:
    git:
      url: https://gitcode.com/OpenHarmony-Flutter/fluttertpc_sentry-dart
      path: dart
      ref: br_3.35

...
```

Execute the command

```bash
flutter pub get
```

<!-- tabs:end -->

### 1.2 Basic Usage

```dart
import 'package:flutter/widgets.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

Future<void> main() async {
  await SentryFlutter.init(
    (options) {
      options.dsn = 'https://example@sentry.io/add-your-dsn-here';
    },
    // Init your App.
    appRunner: () => runApp(MyApp()),
  );
}
```

### 1.3 Tracking Navigation Events

```dart
import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

// ...
MaterialApp(
  navigatorObservers: [
    SentryNavigatorObserver(),
  ],
  // other parameters
)
// ...
```

### 1.4 Performance Tracing for AssetBundles

```dart
runApp(
  DefaultAssetBundle(
    bundle: SentryAssetBundle(),
    child: MyApp(),
  ),
);
```

For a more detailed example, see [example](example/lib/main.dart)

## 2. Constraints & Limitations

### 2.1 Compatibility

Tested and verified on the following versions:

1. Flutter: 3.27.5-ohos-1.0.1; SDK: 5.0.0(12); IDE: DevEco Studio: 5.1.0.828; ROM: 5.1.0.130 SP8;
2. Flutter: 3.35.8-ohos-0.0.2; SDK: 5.0.0(12); IDE: DevEco Studio: 5.1.0.828; ROM: 5.1.0.130 SP8;

### 2.2 OpenHarmony Platform Limitations

Due to the architectural differences of the ohos system, the current implementation provides the basic event reporting functionality of sentry-dart.

- **NDK Crash Capture**: Relies on sentry-native OpenHarmony adaptation; native crashes can be captured but symbolication is not yet supported.
- **Screenshot Attachment (attachScreenshot)**: Not supported. The screenshot operation executes synchronously on the UI thread, causing ANR on OHOS due to excessive duration.
- **Session Replay**: Not supported. The OHOS native screenshot API blocks the main thread synchronously, causing ANR.
- **HTTP Client**: Sentry SDK uses ArkTS native HTTP module; automatic interception of third-party network library requests is not supported.
- **File Cache**: Offline event cache uses app sandbox directory and is subject to system storage quota limits.
- **Battery Status Monitoring**: Some fields like battery temperature depend on system API support and may return default values.

## 3. API

> [!TIP] In the "ohos Support" column, "yes" indicates the feature is supported on the ohos platform; "no" indicates it is not supported; "partially" indicates partial support. Usage is consistent across platforms, with behavior matching iOS or Android.

### 3.1 SentryFlutter

| Name | Description               | Type     | ohos Support |
| ---- | ------------------------- | -------- | ------------ |
| init | Initialize the Sentry SDK | function | yes          |

### 3.2 Sentry Core API

| Name             | Description                                | Type     | ohos Support |
| ---------------- | ------------------------------------------ | -------- | ------------ |
| captureException | Capture and report an exception            | function | yes          |
| captureMessage   | Capture and report a message               | function | yes          |
| captureEvent     | Capture and report an event                | function | yes          |
| addBreadcrumb    | Add a breadcrumb (navigation trail record) | function | yes          |
| configureScope   | Configure scope (set user, tags, etc.)     | function | yes          |
| setUser          | Set current user information               | function | yes          |
| setTag           | Set a tag                                  | function | yes          |
| setExtra         | Set extra data                             | function | yes          |
| startTransaction | Start a performance tracking transaction   | function | yes          |

### 3.3 SentryNavigatorObserver

| Name                    | Description                                            | Type  | ohos Support |
| ----------------------- | ------------------------------------------------------ | ----- | ------------ |
| SentryNavigatorObserver | Navigation event observer for tracking page navigation | class | yes          |

### 3.4 SentryAssetBundle

| Name              | Description                                                       | Type  | ohos Support |
| ----------------- | ----------------------------------------------------------------- | ----- | ------------ |
| SentryAssetBundle | Asset bundle wrapper for tracking AssetBundle loading performance | class | yes          |

### 3.5 SentryOptions Configuration

| Name                      | Description                                           | Type    | Default | ohos Support |
| ------------------------- | ----------------------------------------------------- | ------- | ------- | ------------ |
| dsn                       | Sentry DSN URL                                        | string  | -       | yes          |
| debug                     | Enable debug mode                                     | boolean | false   | yes          |
| release                   | Application version identifier                        | string  | -       | yes          |
| environment               | Environment identifier (e.g., production/development) | string  | -       | yes          |
| dist                      | Distribution version identifier                       | string  | -       | yes          |
| maxBreadcrumbs            | Maximum number of breadcrumbs                         | number  | 50      | yes          |
| tracesSampleRate          | Performance tracing sample rate                       | number  | -       | yes          |
| attachStacktrace          | Attach stack trace to events                          | boolean | false   | yes          |
| enableAutoSessionTracking | Enable auto session tracking                          | boolean | true    | yes          |

### 3.6 OpenHarmony Platform-Specific Features

The following are features supported by the OpenHarmony native SDK:

| Name                       | Description                                                                | Default                                                          | ohos Support |
| -------------------------- | -------------------------------------------------------------------------- | ---------------------------------------------------------------- | ------------ |
| ANR Detection              | Detect Application Not Responding events                                   | Enabled, threshold 5000ms                                        | yes          |
| Frames Tracking            | Detect slow and frozen frames                                              | Enabled, slow frame threshold 48ms, frozen frame threshold 700ms | yes          |
| Auto Breadcrumbs           | Automatically record network status, battery status, app lifecycle changes | Enabled                                                          | yes          |
| UI Interaction Breadcrumbs | Automatically record user interactions like clicks                         | Enabled                                                          | yes          |
| View Hierarchy Capture     | Capture current view hierarchy structure when errors occur                 | Supported                                                        | yes          |
| Activity Lifecycle Tracing | Automatically trace Ability lifecycle performance                          | Enabled                                                          | yes          |
| HTTP Request Breadcrumbs   | Automatically record HTTP requests as breadcrumbs                          | Enabled                                                          | yes          |
| HTTP Request Tracing       | HTTP request performance tracing                                           | Disabled (can be enabled via config)                             | yes          |
| Screenshot Attachment      | Attach a screenshot when an event occurs                                   | Disabled (ANR: toImage blocks main thread)                       | no           |
| Session Replay             | Session recording and playback                                             | Disabled (ANR: window.snapshot blocks main thread)               | no           |
| Global Error Capture       | Automatically capture unhandled exceptions and Promise rejections          | Enabled                                                          | yes          |

## 4. Outstanding Issues

- If you enable the `split-debug-info` feature, you must upload the Debug Symbols manually.
- Layout related errors are only caught by [FlutterError.onError](https://api.flutter.dev/flutter/foundation/FlutterError/onError.html) in debug mode. In release mode, they are removed by the Flutter framework.

## 5. Additional Information

For uploading Debug Symbols and Source Maps, please refer to the [Sentry Flutter official documentation](https://docs.sentry.io/platforms/flutter/upload-debug/).

## 6. License

This project is licensed under [The MIT License](LICENSE).
