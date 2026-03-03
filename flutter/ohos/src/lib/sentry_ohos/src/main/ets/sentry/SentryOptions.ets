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

import { ITransportFactory } from './Transport';
import { Breadcrumb } from './Breadcrumb';
import { SentryEvent } from './SentryEvent';

export class SentryOptions {
  dsn: string = '';
  debug: boolean = false;
  release?: string = '';
  environment?: string = '';
  dist?: string = '';
  serverName?: string = '';
  transportFactory?: ITransportFactory | null = null;
  cacheDirPath?: string | null = null;
  maxBreadcrumbs: number = 100;
  /**
   * Maximum number of cached events/envelopes to keep in offline storage.
   * When the limit is reached, the oldest events will be deleted to make room for new ones.
   * Default is 30 (aligned with Android SDK).
   */
  maxCacheItems: number = 30;
  sdkName: string | null = null;
  // 新增：性能与客户端报告
  autoCommitTransactions?: boolean; // 默认 true
  commitTimeoutMs?: number; // 默认 10000
  // 新增：HiAppEvent Watcher 开关
  enableHiAppWatcher?: boolean; // 默认 true
  // 新增：附件大小限制（字节），用于 external_log 截断
  maxAttachmentBytes?: number; // 默认 524288 (512 KiB)
  // 新增：APP_FREEZE 面包屑额外键上限
  freezeBreadcrumbsMaxKeys?: number; // 默认 8
  // 新增：HiAppEvent 采样率
  crashSampleRate?: number; // 默认 1.0
  freezeSampleRate?: number; // 默认 1.0
  // 采样与追踪
  tracesSampleRate?: number;
  errorsSampleRate?: number;
  releaseHealth?: boolean;
  enableScopePersistence?: boolean;
  // before 回调（对标 Android）
  beforeSend?: (event: SentryEvent) => SentryEvent | null;
  beforeBreadcrumb?: (breadcrumb: Breadcrumb) => Breadcrumb | null;
  // 采样回调
  tracesSampler?: (ctx: TracesSamplingContext) => number | null;
  // Profiling（移动端特性）
  profilesSampleRate?: number;
  profilesSampler?: (ctx: ProfilesSamplingContext) => number | null;
  // 追踪控制
  enableTracing?: boolean;
  tracePropagationTargets?: Array<string>;
  // 其他控制
  attachStacktrace?: boolean;
  enableAutoSessionTracking?: boolean;
  sessionTrackingIntervalMillis?: number;
  sendClientReports?: boolean;
}

// 明确定义采样上下文，避免 any/unknown
export interface SamplingTransactionRef {
  name: string;
  op?: string;
}

export interface TracesSamplingContext {
  transaction?: SamplingTransactionRef;
  parentSampled?: boolean;
}

export interface ProfilesSamplingContext {
  transaction?: SamplingTransactionRef;
}
