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

// 与 Android 对齐：全局 SDK Options 使用 sentry/SentryOptions（类），
// Harmony 核心层使用独立的接口承载额外开关与 HTTP/HiAppEvent 等配置。
import { Breadcrumb } from '../sentry/Breadcrumb';
import { SentryEvent } from '../sentry/SentryEvent';
import { Envelope } from './Types';
import { SentryOptions } from '../sentry/SentryOptions';

type Primitive = string | number | boolean | null | undefined;

export interface SamplingTransactionRef { name: string; op?: string }
export interface TracesSamplingContext { transaction?: SamplingTransactionRef; parentSampled?: boolean }
export interface ProfilesSamplingContext { transaction?: SamplingTransactionRef }

// 对标 Android：平台特定 Options 继承自核心 SentryOptions
export class SentryOhosOptions extends SentryOptions {
  transport?: (payload: Envelope) => Promise<void>;
  anrThresholdMs?: number;
  anrTickerIntervalMs?: number;
  enableAnr?: boolean;
  anrReportInDebug?: boolean;
  cacheDirPath?: string;
  httpEndpoint?: string;
  httpHeaders?: Record<string, string>;
  httpConnectTimeoutMs?: number;
  httpReadTimeoutMs?: number;
  httpMaxRetries?: number;
  httpRetryBaseDelayMs?: number;
  tracesSampleRate?: number;
  errorsSampleRate?: number;
  enableViewHierarchy?: boolean;
  includeViewText?: boolean;
  maxViewNodes?: number;
  maxViewDepth?: number;
  enableReplay?: boolean;
  replayServerUrl?: string;
  autoCommitTransactions?: boolean;
  commitTimeoutMs?: number;
  enableHiAppWatcher?: boolean;
  maxAttachmentBytes?: number;
  freezeBreadcrumbsMaxKeys?: number;
  crashSampleRate?: number;
  freezeSampleRate?: number;
  enableUserInteractionIntegration?: boolean;
  enableUiBreadcrumbs?: boolean;
  enableAppLifecycleBreadcrumbs?: boolean;
  beforeSendEvent?: (event: SentryEvent) => SentryEvent | null;
  beforeBreadcrumbCore?: (breadcrumb: Breadcrumb) => Breadcrumb | null;
  tracesSampler?: (ctx: TracesSamplingContext) => number | null;
  profilesSampleRate?: number;
  profilesSampler?: (ctx: ProfilesSamplingContext) => number | null;
  enableTracing?: boolean;
  tracePropagationTargets?: Array<string>;
  attachStacktrace?: boolean;
  enableAutoSessionTracking?: boolean;
  sessionTrackingIntervalMillis?: number;
  sendClientReports?: boolean;
  enableFramesTracking?: boolean;
  slowFrameThresholdMs?: number;
  frozenFrameThresholdMs?: number;
  framesSampleRate?: number;
  enableActivityLifecycleTracing?: boolean;
  lifecycleTracingTimeoutMs?: number;
  enableNetworkBreadcrumbs?: boolean;
  enableBatteryBreadcrumbs?: boolean;
  enableHttpBreadcrumbs?: boolean;
  enableHttpTracing?: boolean;

  constructor() {
    super();
    // 基类已有默认值，按 Android 习惯覆写本平台默认
    this.sdkName = 'sentry-ohos';
    this.maxBreadcrumbs = 50;
    this.anrThresholdMs = 5000;
    this.anrTickerIntervalMs = 1000;
    this.enableAnr = true;
    this.anrReportInDebug = false;
    this.autoCommitTransactions = true;
    this.commitTimeoutMs = 10000;
    this.enableHiAppWatcher = true;
    this.maxAttachmentBytes = 524288;
    this.freezeBreadcrumbsMaxKeys = 8;
    this.crashSampleRate = 1.0;
    this.freezeSampleRate = 1.0;
    this.enableUserInteractionIntegration = true;
    this.enableUiBreadcrumbs = true;
    this.enableAppLifecycleBreadcrumbs = true;
    this.enableFramesTracking = true;
    this.slowFrameThresholdMs = 48;
    this.frozenFrameThresholdMs = 700;
    this.framesSampleRate = 1.0;
    this.enableActivityLifecycleTracing = true;
    this.lifecycleTracingTimeoutMs = 10000;
    this.enableNetworkBreadcrumbs = true;
    this.enableBatteryBreadcrumbs = true;
    this.enableHttpBreadcrumbs = true;
    this.enableHttpTracing = false;
  }
}

// 为兼容外部以对象字面量方式传参，保留 Init 接口
export interface SentryOhosOptionsInit {
  dsn?: string;
  debug?: boolean;
  release?: string;
  environment?: string;
  dist?: string;
  // Harmony 核心自定义传输（与 sentry/transportFactory 并行存在）
  transport?: (payload: Envelope) => Promise<void>;
  maxBreadcrumbs?: number;
  anrThresholdMs?: number;
  anrTickerIntervalMs?: number;
  enableAnr?: boolean; // 默认 true
  anrReportInDebug?: boolean; // 默认 false（对齐 Android：Debug 下可选择不上报 ANR）
  cacheDirPath?: string;
  httpEndpoint?: string;
  httpHeaders?: Record<string, string>;
  httpConnectTimeoutMs?: number;
  httpReadTimeoutMs?: number;
  httpMaxRetries?: number;
  httpRetryBaseDelayMs?: number;
  tracesSampleRate?: number; // 透传至 sentry/SentryOptions 使用
  errorsSampleRate?: number; // 透传至 sentry/SentryOptions 使用
  enableViewHierarchy?: boolean;
  includeViewText?: boolean;
  maxViewNodes?: number;
  maxViewDepth?: number;
  enableReplay?: boolean;
  replayServerUrl?: string;
  // 帧率检测（对标 Android FramesTracking）
  enableFramesTracking?: boolean; // 默认 true
  slowFrameThresholdMs?: number; // 默认 48ms（约 3 帧）
  frozenFrameThresholdMs?: number; // 默认 700ms
  framesSampleRate?: number; // 默认 1.0
  // 自动 Activity(Ability) 生命周期 Tracing
  enableActivityLifecycleTracing?: boolean; // 默认 true
  lifecycleTracingTimeoutMs?: number; // 默认 10000
  autoCommitTransactions?: boolean;
  commitTimeoutMs?: number;
  enableHiAppWatcher?: boolean;
  maxAttachmentBytes?: number;
  freezeBreadcrumbsMaxKeys?: number;
  crashSampleRate?: number;
  freezeSampleRate?: number;
  enableUserInteractionIntegration?: boolean;
  enableUiBreadcrumbs?: boolean;
  enableAppLifecycleBreadcrumbs?: boolean;
  // 自动面包屑细粒度开关（若 Harmony 能力允许）
  enableNetworkBreadcrumbs?: boolean; // 默认 true
  enableBatteryBreadcrumbs?: boolean; // 默认 true
  enableHttpBreadcrumbs?: boolean; // 默认 true
  enableHttpTracing?: boolean; // 默认 false
  // before 回调
  beforeSendEvent?: (event: SentryEvent) => SentryEvent | null;
  beforeBreadcrumbCore?: (breadcrumb: Breadcrumb) => Breadcrumb | null;
  // 采样回调（Harmony 层保留，与 sentry/SentryOptions 对应）
  tracesSampler?: (ctx: TracesSamplingContext) => number | null;
  profilesSampleRate?: number;
  profilesSampler?: (ctx: ProfilesSamplingContext) => number | null;
  enableTracing?: boolean;
  tracePropagationTargets?: Array<string>;
  attachStacktrace?: boolean;
  enableAutoSessionTracking?: boolean;
  sessionTrackingIntervalMillis?: number;
  sendClientReports?: boolean;
}



