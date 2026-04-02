<p align="center">
  <h1 align="center"> <code>sentry_flutter</code> </h1>
</p>

本项目基于 [sentry_flutter](https://pub.dev/packages/sentry_flutter) 开发，针对 OpenHarmony 平台进行了适配。

## 1. 安装与使用

### 1.1 安装方式

进入到工程目录并在 pubspec.yaml 中添加以下依赖：

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

执行命令

```bash
flutter pub get
```

<!-- tabs:end -->

### 1.2 基本使用

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

### 1.3 导航事件追踪

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

### 1.4 AssetBundle 性能追踪

```dart
runApp(
  DefaultAssetBundle(
    bundle: SentryAssetBundle(),
    child: MyApp(),
  ),
);
```

使用案例详见 [example](example/lib/main.dart)

## 2. 约束与限制

### 2.1 兼容性

在以下版本中已测试通过

1. Flutter: 3.27.5-ohos-1.0.1; SDK: 5.0.0(12); IDE: DevEco Studio: 5.1.0.828; ROM: 5.1.0.130 SP8;
2. Flutter: 3.35.8-ohos-0.0.2; SDK: 5.0.0(12); IDE: DevEco Studio: 5.1.0.828; ROM: 5.1.0.130 SP8; 

### 2.2 OpenHarmony 平台限制说明

由于 ohos 系统架构差异，当前实现了 sentry-dart 基础的事件上报功能。

- **NDK 崩溃捕获**：依赖 sentry-native 的 OpenHarmony 适配实现，可捕获原生崩溃但暂不支持符号化解析。
- **截图附件（attachScreenshot）**：不支持。截图操作在 UI 线程同步执行，在 OHOS 上耗时过长会触发 ANR。
- **Session Replay（会话回放）**：不支持。OHOS 原生截图 API 在主线程同步阻塞，导致 ANR。
- **HTTP 客户端**：Sentry SDK 使用 ArkTS 原生 HTTP 模块，不支持自动拦截第三方网络库请求。
- **文件缓存**：离线事件缓存使用应用沙箱目录，受系统存储配额限制。
- **电池状态监听**：电池温度等部分字段依赖系统 API 支持，可能返回默认值。

## 3. API

> [!TIP] "ohos Support"列为 yes 表示 ohos 平台支持该属性；no 则表示不支持；partially 表示部分支持。使用方法跨平台一致，效果对标 iOS 或 Android 的效果。

### 3.1 SentryFlutter

| Name | Description       | Type     | ohos Support |
| ---- | ----------------- | -------- | ------------ |
| init | 初始化 Sentry SDK | function | yes          |

### 3.2 Sentry 核心 API

| Name             | Description                    | Type     | ohos Support |
| ---------------- | ------------------------------ | -------- | ------------ |
| captureException | 捕获并上报异常                 | function | yes          |
| captureMessage   | 捕获并上报消息                 | function | yes          |
| captureEvent     | 捕获并上报事件                 | function | yes          |
| addBreadcrumb    | 添加面包屑（导航痕迹记录）     | function | yes          |
| configureScope   | 配置作用域（设置用户、标签等） | function | yes          |
| setUser          | 设置当前用户信息               | function | yes          |
| setTag           | 设置标签                       | function | yes          |
| setExtra         | 设置额外数据                   | function | yes          |
| startTransaction | 开始一个性能追踪事务           | function | yes          |

### 3.3 SentryNavigatorObserver

| Name                    | Description                      | Type  | ohos Support |
| ----------------------- | -------------------------------- | ----- | ------------ |
| SentryNavigatorObserver | 导航事件观察者，用于追踪页面导航 | class | yes          |

### 3.4 SentryAssetBundle

| Name              | Description                               | Type  | ohos Support |
| ----------------- | ----------------------------------------- | ----- | ------------ |
| SentryAssetBundle | 资源包装器，用于追踪 AssetBundle 加载性能 | class | yes          |

### 3.5 SentryOptions 配置项

| Name                      | Description                           | Type    | Default | ohos Support |
| ------------------------- | ------------------------------------- | ------- | ------- | ------------ |
| dsn                       | Sentry DSN 地址                       | string  | -       | yes          |
| debug                     | 是否启用调试模式                      | boolean | false   | yes          |
| release                   | 应用版本标识                          | string  | -       | yes          |
| environment               | 环境标识（如 production/development） | string  | -       | yes          |
| dist                      | 分发版本标识                          | string  | -       | yes          |
| maxBreadcrumbs            | 最大面包屑数量                        | number  | 50      | yes          |
| tracesSampleRate          | 性能追踪采样率                        | number  | -       | yes          |
| attachStacktrace          | 是否附加堆栈跟踪                      | boolean | false   | yes          |
| enableAutoSessionTracking | 是否启用自动会话追踪                  | boolean | true    | yes          |

### 3.6 OpenHarmony 平台特有功能

以下为 OpenHarmony 平台原生 SDK 支持的功能特性：

| Name                  | Description                                  | Default                               | ohos Support |
| --------------------- | -------------------------------------------- | ------------------------------------- | ------------ |
| ANR 检测              | 检测应用无响应（Application Not Responding） | 启用，阈值 5000ms                     | yes          |
| 帧率追踪              | 检测慢帧和卡顿帧                             | 启用，慢帧阈值 48ms，卡顿帧阈值 700ms | yes          |
| 自动面包屑            | 自动记录网络状态、电池状态、应用生命周期变化 | 启用                                  | yes          |
| UI 交互面包屑         | 自动记录用户点击等交互事件                   | 启用                                  | yes          |
| 视图层级捕获          | 发生错误时捕获当前视图层级结构               | 支持                                  | yes          |
| Activity 生命周期追踪 | 自动追踪 Ability 生命周期性能                | 启用                                  | yes          |
| HTTP 请求面包屑       | 自动记录 HTTP 请求作为面包屑                 | 启用                                  | yes          |
| HTTP 请求追踪         | HTTP 请求性能追踪                            | 禁用（可配置启用）                    | yes          |
| 截图附件（attachScreenshot）| 事件发生时附加屏幕截图                       | 禁用（ANR：toImage 阻塞主线程）      | no           |
| Session Replay        | 会话录制与回放                               | 禁用（ANR：window.snapshot 阻塞主线程）| no           |
| 全局错误捕获          | 自动捕获未处理的异常和 Promise 拒绝          | 启用                                  | yes          |

## 4. 遗留问题

- 如果启用了 `split-debug-info` 功能，需要手动上传调试符号。
- 布局相关的错误仅在调试模式下被 [FlutterError.onError](https://api.flutter.dev/flutter/foundation/FlutterError/onError.html) 捕获，在发布模式下会被 Flutter 框架移除。

## 5. 其他

关于调试符号和 Source Map 的上传，请参考 [Sentry Flutter 官方文档](https://docs.sentry.io/platforms/flutter/upload-debug/)。

## 6. 开源协议

本项目基于 [The MIT License](LICENSE)开源。
