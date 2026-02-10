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

import { SdkVersion } from "./SdkVersion"

export class SentryEnvelopeHeader {
  eventId?: string
  sdk?: SdkVersion
  dsn?: string

  constructor(eventId?: string, sdk?: SdkVersion, dsn?: string) {
    this.eventId = eventId
    this.sdk = sdk
    this.dsn = dsn
  }

}

export class SentryEnvelopeItem {
  // event, transaction, replay, attachment 等
  type: string
  // 已序列化 JSON 字符串
  payload: string
  length: number

  constructor(type: string, payload: string) {
    this.type = type
    this.payload = payload
    this.length = payload.length
  }

}

// Sentry Envelope
export class SentryEnvelope {
  header: SentryEnvelopeHeader
  items: SentryEnvelopeItem[] = []

  constructor(header: SentryEnvelopeHeader) {
    this.header = header
  }

  addItem(item: SentryEnvelopeItem): void {
    this.items.push(item)
  }

}
