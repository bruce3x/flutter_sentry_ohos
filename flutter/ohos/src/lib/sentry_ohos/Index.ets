/*
 * Copyright (C) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

export { Breadcrumb, BreadcrumbStore } from "./src/main/ets/sentry/Breadcrumb";
export { FileEnvelopeCache } from "./src/main/ets/sentry/Cache";
export { HttpTransport } from "./src/main/ets/sentry/HttpTransport";
export { HttpTransportFactory } from "./src/main/ets/sentry/HttpTransportFactory";
export { Hub } from "./src/main/ets/sentry/Hub";
export { Mechanism } from "./src/main/ets/sentry/Mechanism";
export { Request } from "./src/main/ets/sentry/Request";
export { Scope } from "./src/main/ets/sentry/Scope";
export { SdkVersion } from "./src/main/ets/sentry/SdkVersion";
export { Sentry } from "./src/main/ets/sentry/Sentry";
export { SentryBaseEvent, SentryEvent, SentryReplayEvent, SentryTransaction } from "./src/main/ets/sentry/SentryEvent";
export { SentryException } from "./src/main/ets/sentry/SentryException";
export { SentryLevel } from "./src/main/ets/sentry/SentryLevel";
export { SentryPackage } from "./src/main/ets/sentry/SentryPackage";
export { SentryStackFrame } from "./src/main/ets/sentry/SentryStackFrame";
export { SentryStackTrace } from "./src/main/ets/sentry/SentryStackTrace";
export { SentryThread } from "./src/main/ets/sentry/SentryThread";
export { Session } from "./src/main/ets/sentry/Session";
export { Span } from "./src/main/ets/sentry/Span";
export { SentryOptions } from "./src/main/ets/sentry/SentryOptions"
export { ITransportFactory, ITransport } from "./src/main/ets/sentry/Transport";
export { User } from "./src/main/ets/sentry/User";
export { SentryEnvelope, SentryEnvelopeItem, SentryEnvelopeHeader } from "./src/main/ets/sentry/SentryEnvelope";
export { SentryReplayOptions, ReplayEventListener } from "./src/main/ets/sentry/SentryReplayOptions"
export { Device } from "./src/main/ets/sentry/Device";
export { ClientReport, ClientReportPayload } from "./src/main/ets/sentry/ClientReport";
export { DebugImage, DebugImagesLoader } from "./src/main/ets/sentry/DebugImage";


export { SentryOhos } from './src/main/ets/core/SentryOhos';
export { SentryOhosOptions } from './src/main/ets/core/SentryOhosOptions'
export { installGlobalErrorHandler } from './src/main/ets/core/GlobalError';
export { SpanTimer } from './src/main/ets/core/Performance';
export { SessionTracker } from './src/main/ets/core/Session';
export { AppStartMonitor } from './src/main/ets/core/AppStart';
export { AnrMonitor } from './src/main/ets/core/Anr';
export { withPageRoot } from './src/main/ets/core/withPageRoot';
export { requestWithTrace } from './src/main/ets/core/NetAuto';
export { PageRootDecorator, PageRootHandle } from './src/main/ets/core/PageRootDecorator';
export { InternalSentrySdk } from './src/main/ets/core/InternalSentrySdk';


export { BaseUIEvent, TouchEventType } from './src/main/ets/sentry_ohos_replay/BaseUIEvent'
export { UIComponent, TextInputComponent } from  './src/main/ets/sentry_ohos_replay/Component'
export { EventTransport } from './src/main/ets/sentry_ohos_replay/EventTransport'
export { GestureCapture } from './src/main/ets/sentry_ohos_replay/GestureCapture'
export { InputCapture } from './src/main/ets/sentry_ohos_replay/InputCapture'
export { ReplayCache } from './src/main/ets/sentry_ohos_replay/ReplayCache'
export { ReplayController, ReplayControllerOptions } from './src/main/ets/sentry_ohos_replay/ReplayController'
export { ReplayEvent, ReplayEventData, TouchEventData, InputEventData, FocusEventData, BlurEventData, ScrollEventData } from './src/main/ets/sentry_ohos_replay/ReplayEvent'
export { ReplayTransport } from './src/main/ets/sentry_ohos_replay/ReplayTransport'
export { SamplingConfig } from './src/main/ets/sentry_ohos_replay/SamplingConfig'
export { ScreenCapture } from './src/main/ets/sentry_ohos_replay/ScreenCapture'
export { PrivacyConfig } from './src/main/ets/sentry_ohos_replay/PrivacyConfig'
export { UserActionType, UserActionEvent, SwipeDirection, SnapshotData, ReplayPayload, ReplayPayloadEventData, ReplayPayloadEvent, ReSession } from './src/main/ets/sentry_ohos_replay/types'
export { ViewSnapshot, SnapshotEventData, ArkUIComponent } from './src/main/ets/sentry_ohos_replay/ViewSnapshot'
export {
  startReplay,
  stopReplay,
  getReplayId,
  pauseReplay,
  resumeReplay,
  onAppForeground,
  onAppBackground,
  updateReplayContext,
  configureReplaySampling,
  uploadReplay,
  captureReplayOnError,
  setReplayConnectionStatus,
  setReplayRateLimited,
  registerReplayComponent,
  unregisterReplayComponent,
  maskReplayComponent,
  unmaskReplayComponent,
  setReplayScrollingState,
  ReplayStartOptions
} from './src/main/ets/sentry_ohos_replay/api'
