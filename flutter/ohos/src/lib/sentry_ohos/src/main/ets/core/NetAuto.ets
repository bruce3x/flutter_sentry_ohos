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
import { HttpTracer } from './HttpTrace';
import { BreadcrumbStore, Breadcrumb, SentryLevel } from '../sentry/Breadcrumb';

export interface NetAutoResult {
  status: number;
  data?: string;
}

interface HttpOptions {
  method: http.RequestMethod;
  header?: Record<string, string>;
}

interface HttpResponseLite {
  responseCode: number;
  result?: string;
}

export async function requestWithTrace(method: string, url: string, breadcrumbs: BreadcrumbStore): Promise<NetAutoResult> {
  const tracer = new HttpTracer();
  tracer.start({ method: method, url: url, breadcrumbs: breadcrumbs });

  const client = http.createHttp();
  const header: Record<string, string> = { 'Accept': 'application/json' };
  const options: HttpOptions = {
    method: method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET,
    header: header,
  };

  try {
    const response = await (client.request(url, options) as Promise<HttpResponseLite>);
    const finished = tracer.finish(response.responseCode);
    const bc = new Breadcrumb();
    bc.timestamp = new Date().toISOString();
    bc.message = 'HTTP response';
    bc.category = 'http';
    bc.level = response.responseCode >= 400 ? SentryLevel.Warning : SentryLevel.Info;
    breadcrumbs.add(bc);
    client.destroy();
    const resultStr: string | undefined = typeof response.result === 'string' ? response.result : undefined;
    const ok: NetAutoResult = { status: response.responseCode, data: resultStr };
    return ok;
  } catch (_) {
    tracer.finish(0);
    try { client.destroy(); } catch (_) {}
    const bcErr = new Breadcrumb();
    bcErr.timestamp = new Date().toISOString();
    bcErr.message = 'HTTP error';
    bcErr.category = 'http';
    bcErr.level = SentryLevel.Error;
    breadcrumbs.add(bcErr);
    const fail: NetAutoResult = { status: 0 };
    return fail;
  }
}


