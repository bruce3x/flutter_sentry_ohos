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

import { Span as SdkSpan } from '../sentry/Span';
import type { RRWebSpanEvent, SpanPayload } from './rrweb/RRWebSpanEvent';

export class DefaultReplaySpanConverter {
  public static convert(sp: SdkSpan): RRWebSpanEvent | null {
    if (!sp) return null;
    const payload: SpanPayload = {
      operation: sp.op || 'default',
      description: sp.description,
    };
    if (typeof sp.start_timestamp === 'string' && typeof sp.end_timestamp === 'string') {
      const startMs = Date.parse(sp.start_timestamp);
      const endMs = Date.parse(sp.end_timestamp);
      if (!isNaN(startMs) && !isNaN(endMs) && endMs >= startMs) {
        payload.durationMs = endMs - startMs;
      }
    }
    if (typeof sp.trace_id === 'string') payload.traceId = sp.trace_id;
    if (typeof sp.span_id === 'string') payload.spanId = sp.span_id;
    const ev: RRWebSpanEvent = {
      eventType: 'span',
      timestampMs: Date.now(),
      payload: payload,
    };
    return ev;
  }
}


