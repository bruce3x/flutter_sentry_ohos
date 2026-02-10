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

import { Breadcrumb } from './Breadcrumb';
import { User } from './User';
import { SentryLevel } from './SentryLevel';

export class Scope {
  breadcrumbs: Array<Breadcrumb> = [];
  user: User = new User();
  tags: Record<string, string | null> = {};
  extra: Record<string, Object | null> = {};
  contexts: Record<string, Object | null> = {};
  level?: SentryLevel;
  transactionName?: string;
  fingerprint?: Array<string>;

  addBreadcrumb(breadcrumb: Breadcrumb): void {
    this.breadcrumbs.push(breadcrumb);
  }

  clearBreadcrumbs(): void {
    this.breadcrumbs = [];
  }

  setUser(user: User): void {
    this.user = user;
  }

  setTag(key: string, value: string): void {
    this.tags[key] = value;
  }

  removeTag(key: string): void {
    this.tags[key] = null;
  }

  setExtra(key: string, value: Object): void {
    this.extra[key] = value;
  }

  removeExtra(key: string): void {
    this.extra[key] = null;
  }

  setLevel(level: SentryLevel | undefined): void {
    this.level = level;
  }

  setTransaction(name: string | undefined): void {
    this.transactionName = name;
  }

  setFingerprint(list: Array<string> | undefined): void {
    this.fingerprint = list ? list.slice() : undefined;
  }

  setContext(key: string, value: Object): void {
    this.contexts[key] = value;
  }

  removeContext(key: string): void {
    this.contexts[key] = null;
  }

  clone(): Scope {
    const newScope = new Scope();

    // 拷贝 breadcrumbs
    newScope.breadcrumbs = [];
    for (let i = 0; i < this.breadcrumbs.length; i++) {
      const b = this.breadcrumbs[i];
      const breadcrumb = new Breadcrumb();
      breadcrumb.timestamp = b.timestamp;
      breadcrumb.category = b.category;
      breadcrumb.level = b.level;
      breadcrumb.message = b.message;
      breadcrumb.type = b.type;
      breadcrumb.data = b.data;
      newScope.breadcrumbs[i] = breadcrumb;
    }
    // 拷贝 user（全局单例默认存在）
    const user = new User()
    user.id = this.user.id;
    user.username = this.user.username;
    user.email = this.user.email;
    user.ip_address = this.user.ip_address;
    user.segment = this.user.segment;
    user.extras = this.user.extras;
    newScope.user = user;

    // 拷贝 tags
    newScope.tags = {};
    for (let i = 0; i < Object.keys(this.tags).length; i++) {
      const key = Object.keys(this.tags)[i];
      newScope.tags[key] = this.tags[key];
    }

    // 拷贝 extra
    newScope.extra = {};
    for (let i = 0; i < Object.keys(this.extra).length; i++) {
      const key = Object.keys(this.extra)[i];
      newScope.extra[key] = this.extra[key];
    }

    // 拷贝 contexts
    newScope.contexts = {};
    for (let i = 0; i < Object.keys(this.contexts).length; i++) {
      const key = Object.keys(this.contexts)[i];
      newScope.contexts[key] = this.contexts[key];
    }

    // 拷贝 level/transaction/fingerprint
    newScope.level = this.level;
    newScope.transactionName = this.transactionName;
    newScope.fingerprint = this.fingerprint ? this.fingerprint.slice() : undefined;

    return newScope;
  }
}
