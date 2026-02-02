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

import { SentryEvent } from './SentryEvent';
import { SentryOptions } from './SentryOptions';

export interface ITransport {
  send(event: SentryEvent): Promise<boolean>;
  // 直接发送已序列化的 Sentry Envelope（原始字节）。
  // 用于 Hybrid SDK 从上层（如 Flutter）传入的原始 envelope 透传。
  sendRawEnvelope?(envelope: Uint8Array): Promise<boolean>;
  flush(timeout?: number): Promise<boolean>;
  close(): void;
}

export interface ITransportFactory {
  create(options: SentryOptions): ITransport;
}
