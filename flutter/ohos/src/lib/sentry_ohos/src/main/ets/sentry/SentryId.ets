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

export class SentryId {
  private _id: string;

  constructor(id?: string) {
    this._id = typeof id === 'string' && id.length > 0 ? id : SentryId.EMPTY_VALUE;
  }

  static get EMPTY_VALUE(): string { return '00000000000000000000000000000000'; }

  static empty(): SentryId { return new SentryId(SentryId.EMPTY_VALUE); }

  static fromId(id: string): SentryId { return new SentryId(id); }

  toString(): string { return this._id; }
}


