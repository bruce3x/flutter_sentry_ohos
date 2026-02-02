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

export class User {
  id?: string;
  username?: string;
  email?: string;
  ip_address?: string;
  segment?: string;
  extras?: Record<string, string>;

  constructor(init?: Partial<User>) {
    if (init) {
      this.id = init.id;
      this.username = init.username;
      this.email = init.email;
      this.ip_address = init.ip_address;
      this.segment = init.segment;
      this.extras = init.extras;
    };
  }
}
