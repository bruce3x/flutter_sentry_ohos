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

import { Breadcrumb } from "../sentry/Breadcrumb";

export type Primitive = string | number | boolean | null | undefined;

export interface EnvelopeDataUnknown {
  // 统一占位类型，避免使用 unknown
  // 实际数据由上层严格类型定义（MessageData/ExceptionData/SpanData）
}

export interface Envelope {
  type: 'message' | 'exception' | 'span' | 'anr' | 'session';
  release?: string;
  environment?: string;
  timestamp: string;
  device: Record<string, Primitive>;
  app: Record<string, Primitive>;
  data: EnvelopeDataUnknown | object;
  breadcrumbs: Array<Breadcrumb>;
  session?: object;
  contexts?: Record<string, Object>;
}


