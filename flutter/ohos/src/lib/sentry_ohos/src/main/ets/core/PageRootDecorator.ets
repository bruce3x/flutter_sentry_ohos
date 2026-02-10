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

import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import { ViewRegistry, ViewNode, ViewBounds } from './ViewRegistry';
import { SentryOhos } from './SentryOhos';
import { Breadcrumb as CoreBreadcrumb, SentryLevel } from '../sentry/Breadcrumb';

interface WindowRectLike { left?: number; top?: number; width?: number; height?: number }
interface WindowPropsLike { windowRect?: WindowRectLike }
// 使用 SDK 自带 Window 类型的 getWindowProperties()

export interface PageRootOptions {
  id: string;
  type?: string;
  testId?: string;
  context: common.BaseContext;
}

export class PageRootHandle {
  private id: string;
  private type: string;
  private testId?: string;
  private context: common.BaseContext;
  private lastWidth?: number;
  private lastHeight?: number;

  constructor(opts: PageRootOptions) {
    this.id = opts.id;
    this.type = opts.type ? opts.type : 'PageRoot';
    this.testId = opts.testId;
    this.context = opts.context;
  }

  attach(): void {
    const node: ViewNode = {
      id: this.id,
      type: this.type,
      bounds: { x: 0, y: 0, width: 0, height: 0 },
      visible: true,
      opacity: 1,
      testId: this.testId,
      children: [],
      parentId: undefined,
    };
    ViewRegistry.get().register(node);
    // 异步刷新尺寸
    this.refreshBounds().catch(() => {});
  }

  async refreshBounds(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context);
      const propsObj = win.getWindowProperties();
      const rect = this.extractRect(propsObj);
      if (rect) {
        const node: ViewNode = {
          id: this.id,
          type: this.type,
          bounds: { x: rect.left || 0, y: rect.top || 0, width: rect.width || 0, height: rect.height || 0 },
          visible: true,
          opacity: 1,
          testId: this.testId,
          children: [],
          parentId: undefined,
        };
        ViewRegistry.get().update(node);
        // 记录屏幕尺寸变化面包屑
        try {
          const newW = node.bounds.width;
          const newH = node.bounds.height;
          const changed = (this.lastWidth !== newW) || (this.lastHeight !== newH);
          if (changed) {
            const bc = new CoreBreadcrumb();
            bc.timestamp = new Date().toISOString();
            bc.message = 'Screen size changed';
            bc.category = 'device.screen';
            bc.level = SentryLevel.Info;
            const rec: Record<string, string> = {};
            rec['new_width'] = String(newW);
            rec['new_height'] = String(newH);
            bc.data = rec;
            SentryOhos.addBreadcrumb(bc);
            this.lastWidth = newW;
            this.lastHeight = newH;
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  setVisible(visible: boolean): void {
    const snap = ViewRegistry.get().snapshot();
    const found = snap.nodes[this.id];
    if (!found) return;
    const node: ViewNode = {
      id: found.id,
      type: found.type,
      bounds: found.bounds,
      visible: visible,
      opacity: found.opacity,
      testId: found.testId,
      children: found.children,
      parentId: found.parentId,
    };
    ViewRegistry.get().update(node);
  }

  dispose(): void {
    ViewRegistry.get().unregister(this.id);
  }

  private extractRect(propsObj: object): WindowRectLike | undefined {
    const rec = propsObj as Record<string, number | string | boolean | object>;
    const inner = (typeof rec['windowRect'] === 'object')
      ? (rec['windowRect'] as Record<string, number | string | boolean | object>)
      : rec;
    const out: ViewBounds = {
      x: this.readNumber(inner, 'left') || 0,
      y: this.readNumber(inner, 'top') || 0,
      width: this.readNumber(inner, 'width') || 0,
      height: this.readNumber(inner, 'height') || 0,
    };
    return out;
  }

  private readNumber(obj: Record<string, number | string | boolean | object>, key: string): number | undefined {
    const v = obj[key];
    if (typeof v === 'number') return v;
    if (typeof v === 'string') {
      const n = parseFloat(v);
      return isNaN(n) ? undefined : n;
    }
    return undefined;
  }
}

export class PageRootDecorator {
  static attach(opts: PageRootOptions): PageRootHandle {
    const handle = new PageRootHandle(opts);
    handle.attach();
    return handle;
  }
}


