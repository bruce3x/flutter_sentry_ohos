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

import { nowMs } from './HarmonyUtilsAdapter';

export interface SessionState {
  id: string;
  startedMs: number;
  endedMs?: number;
  errors: number;
}

export class SessionTracker {
  private current: SessionState | undefined;

  start(): SessionState {
    const s: SessionState = {
      id: String(nowMs()),
      startedMs: nowMs(),
      errors: 0,
    };
    this.current = s;
    return s;
  }

  end(): SessionState | undefined {
    if (!this.current) return undefined;
    this.current.endedMs = nowMs();
    const ended = this.current;
    this.current = undefined;
    return ended;
  }

  error(): void {
    if (this.current) this.current.errors += 1;
  }

  get(): SessionState | undefined {
    return this.current;
  }
}




