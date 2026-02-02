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

import { SentryOhos } from './SentryOhos'
import { AbilityLifecycleBreadcrumbs } from './AbilityLifecycleBreadcrumbs'
import { GestureCapture } from '../sentry_ohos_replay/GestureCapture'

export interface UserInteractionOptions {
  enableUiBreadcrumbs?: boolean; // default true
  enableAppLifecycleBreadcrumbs?: boolean; // default true
}

export class UserInteractionIntegration {
  private static installed: boolean = false;
  private static abilityBc: AbilityLifecycleBreadcrumbs | null = null;

  static install(opts?: UserInteractionOptions): void {
    if (UserInteractionIntegration.installed) return;
    const enableUi = (opts && opts.enableUiBreadcrumbs) !== undefined ? (opts as UserInteractionOptions).enableUiBreadcrumbs : true;
    const enableApp = (opts && opts.enableAppLifecycleBreadcrumbs) !== undefined ? (opts as UserInteractionOptions).enableAppLifecycleBreadcrumbs : true;
    try {
      if (enableApp) {
        const store = SentryOhos.getBreadcrumbStore ? SentryOhos.getBreadcrumbStore() : null;
        if (store) {
          UserInteractionIntegration.abilityBc = new AbilityLifecycleBreadcrumbs(store);
        }
        // 在应用上下文设置后由 SentryOhos 调用 abilityBc.install(appContext)
      }
      if (enableUi) {
        // UI 点击等统一通过 GestureCapture（已经将 click 转换为 ui.click 面包屑）
        // 具体页面中应注册 GestureCapture.attach(component)
      }
      UserInteractionIntegration.installed = true;
    } catch (_) {}
  }
}


