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

import { SentryLevel } from "./SentryLevel";

export class Breadcrumb {
  timestamp: string;
  message?: string;
  category?: string;
  level?: SentryLevel;
  type?: string;
  data?: Record<string, string>;

  constructor(init?: Partial<Breadcrumb>) {
    this.timestamp = init?.timestamp ?? new Date().toISOString();
    if (init) {
      this.message = init.message;
      this.category = init.category;
      this.level = init.level;
      this.type = init.type;
      this.data = init.data;
    };
  }

}

export class BreadcrumbStore {
  private items: Array<Breadcrumb> = [];
  private capacity: number;

  constructor(capacity: number) {
    this.capacity = capacity;
  }

  add(b: Breadcrumb): void {
    this.items.push(b);
    if (this.items.length > this.capacity) {
      // 移除最早的
      this.items.splice(0, 1);
    }
  }

  snapshot(): Array<Breadcrumb> {
    const out: Array<Breadcrumb> = [];
    for (let i = 0; i < this.items.length; i++) out.push(this.items[i]);
    return out;
  }
}


export { SentryLevel };
