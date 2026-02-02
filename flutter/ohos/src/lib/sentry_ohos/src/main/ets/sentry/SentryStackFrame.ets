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

export class SentryStackFrame {
  filename?: string;
  function?: string;
  module?: string;
  lineno?: number;
  colno?: number;
  abs_path?: string;
  in_app?: boolean;
  vars?: Record<string, string>;
  context_line?: string;
  pre_context?: Array<string>;
  post_context?: Array<string>;

  constructor(init?: Partial<SentryStackFrame>) {
    if (init) {
      this.filename = init.filename;
      this.function = init.function;
      this.module = init.module;
      this.lineno = init.lineno;
      this.colno = init.colno;
      this.abs_path = init.abs_path;
      this.in_app = init.in_app;
      this.vars = init.vars;
      this.context_line = init.context_line;
      this.pre_context = init.pre_context;
      this.post_context = init.post_context;
    };
  }
}
