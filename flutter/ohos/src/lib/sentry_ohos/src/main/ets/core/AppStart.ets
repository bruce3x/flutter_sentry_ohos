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

export interface AppStartTiming {
  coldStartMs?: number;
  markAppLaunchedAtMs?: number;
}

export class AppStartMonitor {
  private appLaunchedAtMs: number | undefined;
  private firstPageBuiltAtMs: number | undefined;

  markAppLaunched(): void {
    this.appLaunchedAtMs = nowMs();
  }

  markFirstPageBuilt(): AppStartTiming {
    this.firstPageBuiltAtMs = nowMs();
    const out: AppStartTiming = { markAppLaunchedAtMs: this.appLaunchedAtMs };
    if (this.appLaunchedAtMs !== undefined) out.coldStartMs = this.firstPageBuiltAtMs - this.appLaunchedAtMs;
    return out;
  }
}




