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

import { UIComponent } from '../sentry_ohos_replay/Component';
import { BaseUIEvent } from '../sentry_ohos_replay/BaseUIEvent';
import { registerReplayComponent as reg, unregisterReplayComponent as unreg } from '../sentry_ohos_replay/api';

export function mapArkTouchType(arkType: string): 'down' | 'move' | 'up' | 'longPress' {
  switch (arkType) {
    case 'touchStart': return 'down';
    case 'touchMove':  return 'move';
    case 'touchEnd':   return 'up';
    default:           return 'move';
  }
}

export interface AutoUIComponentHandle {
  ui: UIComponent;
  emit: (arkType: string, x?: number, y?: number, pointerId?: number) => void;
}

class SimpleUIComponent implements UIComponent {
  public id: string;
  private cb?: (e: BaseUIEvent) => void;

  constructor(id: string) {
    this.id = id;
  }

  public onTouch(fn: (event: BaseUIEvent) => void): void {
    this.cb = fn;
  }

  public offTouch(fn: (event: BaseUIEvent) => void): void {
    if (this.cb === fn) this.cb = undefined;
  }

  public dispatchTouchEvent(evt: BaseUIEvent): void {
    if (this.cb) this.cb(evt);
  }
}

export function makeUIComponent(id: string): AutoUIComponentHandle {
  const ui = new SimpleUIComponent(id);
  const handle: AutoUIComponentHandle = {
    ui: ui,
    emit: (arkType: string, x: number = 0, y: number = 0, pointerId: number = 0): void => {
      const type = mapArkTouchType(arkType);
      const evt: BaseUIEvent = { type, targetId: id, timestamp: Date.now(), x, y, pointerId };
      ui.dispatchTouchEvent(evt);
    }
  };
  return handle;
}

export function registerOnAppear(pageThis: ESObject, ...items: UIComponent[]): void {
  items.forEach((it: UIComponent) => reg(it, pageThis));
}

export function unregisterOnDisappear(...items: UIComponent[]): void {
  items.forEach((it: UIComponent) => unreg(it));
}
