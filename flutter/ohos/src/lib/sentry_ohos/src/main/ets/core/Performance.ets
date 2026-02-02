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

import { nowMs } from './HarmonyUtilsAdapter';

export interface SpanContext {
  name: string;
  startMs?: number;
  endMs?: number;
  attrs?: Object;
  startIso?: string;
  endIso?: string;
}

export class SpanTimer {
  private context: SpanContext;

  constructor(name: string, attrs?: Object) {
    this.context = { name: name, startMs: nowMs(), attrs: attrs };
  }

  end(extraAttrs?: Object): SpanContext {
    if (!this.context.endMs) this.context.endMs = nowMs();
    // 同时保留 ISO 时间戳（更贴近 transaction 序列化）
    this.context.startIso = this.context.startMs !== undefined ? new Date(this.context.startMs).toISOString() : undefined;
    this.context.endIso = this.context.endMs !== undefined ? new Date(this.context.endMs).toISOString() : undefined;
    if (extraAttrs) {
      // ArkTS 规则下避免使用 for-in/标准库：简单覆盖 attrs
      this.context.attrs = extraAttrs;
    }
    return this.context;
  }

  toJSON(): SpanContext {
    // 直接返回已有上下文，避免对象复制与标准库限制
    return this.context;
  }
}

export interface MeasureResult<T> {
  value: T;
  span: SpanContext;
}

export function measure<T>(name: string, fn: () => T, attrs?: Record<string, string | number | boolean>): MeasureResult<T> {
  const timer = new SpanTimer(name, attrs);
  let value: T;
  try {
    value = fn();
  } finally {
    timer.end();
  }
  const resultObj: MeasureResult<T> = { value: value, span: timer.toJSON() };
  return resultObj;
}


