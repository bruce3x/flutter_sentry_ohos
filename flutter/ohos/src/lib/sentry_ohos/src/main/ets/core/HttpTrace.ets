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

import { Breadcrumb, BreadcrumbStore } from '../sentry/Breadcrumb';
import { SentryLevel } from '../sentry/SentryLevel';
import { SpanTimer } from './Performance';

export interface HttpStartOptions {
  method: string;
  url: string;
  breadcrumbs: BreadcrumbStore;
}

export interface HttpFinishResult {
  durationMs?: number;
  status: number;
}

export class HttpTracer {
  private breadcrumbs: BreadcrumbStore | undefined;
  private span: SpanTimer | undefined;
  private method: string = 'GET';
  private url: string = '';

  constructor() {}

  start(opts: HttpStartOptions): void {
    this.method = opts.method;
    this.url = opts.url;
    this.breadcrumbs = opts.breadcrumbs;
    const attrs: Record<string, string | number | boolean> = {};
    attrs['method'] = this.method;
    attrs['url'] = this.url;
    this.span = new SpanTimer('http.client', attrs);

    const dataObj: Record<string, string | number | boolean> = {};
    dataObj['method'] = this.method;
    dataObj['url'] = this.url;

    const bc = new Breadcrumb();
    bc.timestamp = new Date().toISOString();
    bc.message = 'HTTP request';
    bc.category = 'http';
    bc.level = SentryLevel.Info;
    // ArkTS: data 为 Record<string,string>
    const dataStr: Record<string, string> = {};
    const keys = Object.keys(dataObj);
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      const v = dataObj[k];
      dataStr[k] = typeof v === 'string' ? v : String(v);
    }
    bc.data = dataStr;
    if (this.breadcrumbs) this.breadcrumbs.add(bc);
  }

  finish(status: number): HttpFinishResult {
    const out: HttpFinishResult = { status: status };
    if (!this.span) return out;
    const endAttrs: Record<string, string | number | boolean> = {};
    endAttrs['status'] = status;
    const ctx = this.span.end(endAttrs);
    if (ctx.endMs !== undefined && ctx.startMs !== undefined) out.durationMs = (ctx.endMs - ctx.startMs);
    return out;
  }
}



