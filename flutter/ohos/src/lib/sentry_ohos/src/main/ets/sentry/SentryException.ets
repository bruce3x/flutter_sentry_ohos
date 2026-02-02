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

import { Mechanism } from './Mechanism';
import { SentryStackTrace } from './SentryStackTrace';

export class SentryException {
  type?: string;
  value?: string;
  module?: string;
  stacktrace?: SentryStackTrace;
  mechanism?: Mechanism;
  threadId?: number;

  constructor(init?: Partial<SentryException>) {
    if (init) {
      this.type = init.type;
      this.value = init.value;
      this.module = init.module;
      this.stacktrace = init.stacktrace;
      this.mechanism = init.mechanism;
      // 非必填：线程 id（用于异常 value.thread_id 输出）
      if (init.threadId !== undefined) this.threadId = init.threadId;
    };
  }
}
