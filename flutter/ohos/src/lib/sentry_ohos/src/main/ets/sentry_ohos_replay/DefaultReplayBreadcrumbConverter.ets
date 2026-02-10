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

import { Breadcrumb as SdkBreadcrumb } from '../sentry/Breadcrumb';
import type { RRWebBreadcrumbEvent, BreadcrumbPayload } from './rrweb/RRWebBreadcrumbEvent';

export class DefaultReplayBreadcrumbConverter {
  public static convert(b: SdkBreadcrumb): RRWebBreadcrumbEvent | null {
    if (!b || !b.timestamp) return null;
    const payload: BreadcrumbPayload = {
      category: b.category || 'default',
    };
    if (b.level) payload.level = String(b.level);
    if (b.message) payload.message = b.message;
    if (b.data) {
      const out: Record<string, string> = {};
      const keys = Object.keys(b.data);
      for (let i = 0; i < keys.length; i++) {
        const k = keys[i];
        const v = (b.data as Record<string, Object>)[k];
        out[k] = v === null || v === undefined ? String(v) : (typeof v === 'string' ? v : String(v));
      }
      payload.data = out;
    }
    // Breadcrumb.timestamp 为字符串 ISO，转毫秒
    let tsMs: number = Date.now();
    try {
      if (typeof b.timestamp === 'string') {
        const parsed = Date.parse(b.timestamp);
        if (!isNaN(parsed)) tsMs = parsed;
      }
    } catch (_) {}
    const ev: RRWebBreadcrumbEvent = {
      eventType: 'breadcrumb',
      timestampMs: tsMs,
      payload: payload,
    };
    return ev;
  }
}


