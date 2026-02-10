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

export class Span {
  trace_id: string;
  span_id: string;
  parent_span_id?: string;
  op?: string;
  description?: string;
  start_timestamp: string;
  end_timestamp?: string;
  status?: string;
  data?: Record<string, string>;

  constructor(trace_id: string, span_id: string, start_timestamp: string) {
    this.trace_id = trace_id;
    this.span_id = span_id;
    this.start_timestamp = start_timestamp;
  }
}
