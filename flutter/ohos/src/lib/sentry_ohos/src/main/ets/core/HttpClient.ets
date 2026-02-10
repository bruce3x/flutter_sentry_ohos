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

import http from '@ohos.net.http';
import { Breadcrumb, BreadcrumbStore, SentryLevel } from '../sentry/Breadcrumb';
import { HttpTracer } from './HttpTrace';
import { SentryOhos } from './SentryOhos';

export interface HttpResult { status: number; data?: string }

interface HttpResponseLite { responseCode: number; result?: string }
interface HttpRequestOptions { method: http.RequestMethod; header?: Record<string, string>; extraData?: string }

export class SentryHttpClient {
  private breadcrumbs?: BreadcrumbStore;
  constructor(bc?: BreadcrumbStore) { this.breadcrumbs = bc; }

  async get(url: string): Promise<HttpResult> {
    const enable = SentryOhos.isHttpBreadcrumbsEnabled() || SentryOhos.isHttpTracingEnabled();
    if (enable && this.breadcrumbs) {
      return await this.requestTraced('GET', url);
    }
    return await this.requestPlain('GET', url);
  }

  async post(url: string, body?: string, headers?: Record<string, string>): Promise<HttpResult> {
    const enable = SentryOhos.isHttpBreadcrumbsEnabled() || SentryOhos.isHttpTracingEnabled();
    if (enable && this.breadcrumbs) {
      return await this.requestTraced('POST', url, body, headers);
    }
    return await this.requestPlain('POST', url, body, headers);
  }

  private async requestTraced(method: 'GET' | 'POST', url: string, body?: string, headers?: Record<string, string>): Promise<HttpResult> {
    const tracer = new HttpTracer();
    tracer.start({ method: method, url: url, breadcrumbs: this.breadcrumbs as BreadcrumbStore });
    const client = http.createHttp();
    const opt: HttpRequestOptions = {
      method: method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET,
    };
    if (headers) opt.header = headers;
    if (typeof body === 'string') opt.extraData = body;
    try {
      const res = await (client.request(url, opt) as Promise<HttpResponseLite>);
      tracer.finish(res.responseCode);
      const bc = new Breadcrumb();
      bc.timestamp = new Date().toISOString();
      bc.message = 'HTTP response';
      bc.category = 'http';
      bc.level = res.responseCode >= 400 ? SentryLevel.Warning : SentryLevel.Info;
      (this.breadcrumbs as BreadcrumbStore).add(bc);
      client.destroy();
      const dataStr: string | undefined = typeof res.result === 'string' ? res.result : undefined;
      return { status: res.responseCode, data: dataStr } as HttpResult;
    } catch (_) {
      tracer.finish(0);
      try { client.destroy(); } catch (_) {}
      const bcErr = new Breadcrumb();
      bcErr.timestamp = new Date().toISOString();
      bcErr.message = 'HTTP error';
      bcErr.category = 'http';
      bcErr.level = SentryLevel.Error;
      (this.breadcrumbs as BreadcrumbStore).add(bcErr);
      return { status: 0 } as HttpResult;
    }
  }

  private async requestPlain(method: 'GET' | 'POST', url: string, body?: string, headers?: Record<string, string>): Promise<HttpResult> {
    const client = http.createHttp();
    const opt: HttpRequestOptions = {
      method: method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET,
    };
    if (headers) opt.header = headers;
    if (typeof body === 'string') opt.extraData = body;
    try {
      const res = await (client.request(url, opt) as Promise<HttpResponseLite>);
      client.destroy();
      const dataStr: string | undefined = typeof res.result === 'string' ? res.result : undefined;
      return { status: res.responseCode, data: dataStr } as HttpResult;
    } catch (_) {
      try { client.destroy(); } catch (_) {}
      return { status: 0 } as HttpResult;
    }
  }
}


