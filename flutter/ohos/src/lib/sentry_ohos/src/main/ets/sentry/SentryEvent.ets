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

import { SentryLevel } from './SentryLevel';
import { SentryMessage } from './SentryMessage';
import { User } from './User';
import { Request } from './Request';
import { Breadcrumb } from './Breadcrumb';
import { SentryException } from './SentryException';
import { SentryThread } from './SentryThread';
import { SdkVersion } from './SdkVersion';
import { Span } from './Span';


export abstract class SentryBaseEvent {
  event_id: string
  timestamp: string;
  platform?: string
  environment?: string
  release?: string
  dist?: string
  // 附加数据
  tags: Record<string, string> = {}
  extras: Record<string, string> = {}
  // 上下文信息
  user?: User
  request?: Request
  breadcrumbs: Array<Breadcrumb> = []
  contexts: Record<string, Object> = {}
  level?: SentryLevel
  sdk?: SdkVersion
  server_name?: string
  fingerprint?: Array<string>;
  eventProcessors?: Array<(event: SentryBaseEvent) => SentryBaseEvent>

  constructor(eventId: string) {
    this.event_id = SentryEvent.generateEventId();
    this.platform = "ohos";
    this.timestamp = new Date().toISOString();
    // 设置 sdk 元信息，便于服务端识别来源
    const sdk = new SdkVersion();
    sdk.name = 'sentry-ohos';
    sdk.version = '0.1.0';
    this.sdk = sdk;
  }

  static generateEventId(): string {
    return Math.random().toString(36).substring(2, 10) + Date.now().toString(36);
  }

}

export class SentryEvent extends SentryBaseEvent {
  message?: SentryMessage
  throwable?: string
  threads: Array<SentryThread> = []
  exceptions: Array<SentryException> = []

  constructor(message?: string) {
    super(SentryEvent.generateEventId())
    if (message) this.message = new SentryMessage(message);
  }

}

export class SentryReplayEvent extends SentryBaseEvent {
  segmentId: number
  replayType: string
  urls: Array<string> = []

  constructor(segmentId: number, replayType: string) {
    super(SentryEvent.generateEventId())
    this.segmentId = segmentId
    this.replayType = replayType
  }

}

export class SentryTransaction extends SentryBaseEvent {
  transaction: string
  spans: Array<Span> = []
  measurements: Record<string, TransactionMeasurement> = {}

  constructor(transaction: string) {
    super(SentryEvent.generateEventId())
    this.transaction = transaction
  }

  setMeasurement(key: string, value: number, unit?: string): void {
    const entry: TransactionMeasurement = { value: value, unit: unit };
    // ArkTS 允许对象字段索引写入，这里直接更新现有对象，避免整体替换造成类型检查冲突
    (this.measurements as Record<string, TransactionMeasurement>)[key] = entry;
  }

}

export interface TransactionMeasurement {
  value: number;
  unit?: string;
}

