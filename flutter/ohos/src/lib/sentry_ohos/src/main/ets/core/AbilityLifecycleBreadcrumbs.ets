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

import { BreadcrumbStore, Breadcrumb, SentryLevel } from '../sentry/Breadcrumb';
import { TraceManager } from './TraceManager';
import { Sentry } from '../sentry/Sentry';

type Primitive = string | number | boolean | null | undefined;

interface AbilityObjLike {
  abilityName?: string;
}

interface AbilityLifecycleCbLike {
  onAbilityForeground?: (ability: AbilityObjLike) => void;
  onAbilityBackground?: (ability: AbilityObjLike) => void;
}

interface AppContextLike {
  registerAbilityLifecycleCallback?: (cb: AbilityLifecycleCbLike) => void;
  unregisterAbilityLifecycleCallback?: (cb: AbilityLifecycleCbLike) => void;
}

interface ConstructorWithOptionalName {
  name?: string;
}

export class AbilityLifecycleBreadcrumbs {
  private store: BreadcrumbStore;
  private cb?: AbilityLifecycleCbLike;
  private tracingEnabled: boolean = false;
  private tracingTimeoutMs: number = 10000;

  constructor(store: BreadcrumbStore) {
    this.store = store;
  }

  install(appContext: object, tracingEnabled?: boolean, tracingTimeoutMs?: number): void {
    const ctx = appContext as AppContextLike;
    if (!ctx || typeof ctx.registerAbilityLifecycleCallback !== 'function') return;
    this.tracingEnabled = tracingEnabled === true;
    if (typeof tracingTimeoutMs === 'number') this.tracingTimeoutMs = tracingTimeoutMs;
    const self = this;
    this.cb = {
      onAbilityForeground: (ability: AbilityObjLike) => {
        self.addLifecycleBreadcrumb('foreground', ability);
        if (self.tracingEnabled) {
          try {
            const name = self.readAbilityName(ability) || 'Ability';
            TraceManager.get().startTransaction(name, 'ui.lifecycle', self.tracingTimeoutMs, true);
          } catch (_) {}
        }
      },
      onAbilityBackground: (ability: AbilityObjLike) => {
        self.addLifecycleBreadcrumb('background', ability);
        if (self.tracingEnabled) {
          try {
            const txn = TraceManager.get().commit();
            if (txn) {
              Sentry.captureTransaction(txn);
            }
          } catch (_) {}
        }
      }
    } as AbilityLifecycleCbLike;
    try { ctx.registerAbilityLifecycleCallback(this.cb); } catch (_) {}
  }

  uninstall(appContext: object): void {
    const ctx = appContext as AppContextLike;
    if (!ctx || typeof ctx.unregisterAbilityLifecycleCallback !== 'function') return;
    if (!this.cb) return;
    try { ctx.unregisterAbilityLifecycleCallback(this.cb); } catch (_) {}
    this.cb = undefined;
  }

  private addLifecycleBreadcrumb(state: string, ability: AbilityObjLike | undefined): void {
    const bc = new Breadcrumb();
    bc.timestamp = new Date().toISOString();
    bc.message = 'App Lifecycle';
    bc.category = 'app.lifecycle';
    bc.level = SentryLevel.Info;
    const rec: Record<string, string> = {};
    rec['state'] = state;
    const name = this.readAbilityName(ability);
    if (name) rec['ability'] = name;
    bc.data = rec;
    this.store.add(bc);
  }

  private readAbilityName(ability: AbilityObjLike | undefined): string | undefined {
    if (!ability) return undefined;
    if (typeof ability.abilityName === 'string') return ability.abilityName;
    // 回退：尝试从 constructor 名称获取
    try {
      const anyRec = ability as Record<string, Primitive>;
      const ctor = (ability as object).constructor as ConstructorWithOptionalName;
      if (ctor && typeof ctor.name === 'string') return ctor.name;
      const nameMaybe = anyRec['name'];
      if (typeof nameMaybe === 'string') return nameMaybe;
    } catch (_) {}
    return undefined;
  }
}


