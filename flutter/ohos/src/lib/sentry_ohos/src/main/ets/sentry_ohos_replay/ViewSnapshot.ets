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

import { UIComponent } from './Component';
import { PrivacyConfig } from './PrivacyConfig';
import { SpanTimer } from '../core/Performance';
import { TraceManager } from '../core/TraceManager';

export interface SnapshotEventData {
  componentId: string;
  imageBase64: string;
  width: number;
  height: number;
}

export interface ArkUIComponent {
  renderToPixelMap(): Promise<PixelMap>;
}


// 页面快照
export class ViewSnapshot {
  private registeredComponents: UIComponent[];
  private componentMap: Map<string, ArkUIComponent>;
  private privacy: PrivacyConfig;

  constructor(privacy?: PrivacyConfig) {
    this.registeredComponents = [];
    this.componentMap = new Map<string, ArkUIComponent>();
    this.privacy = privacy ?? new PrivacyConfig();
  }

  /**
   * 注册需要捕获快照的组件
   * @param component UIComponent
   */
  public registerComponent(customComp: UIComponent, arkComp: ESObject): void {
    if (!this.registeredComponents.includes(customComp)) {
      this.registeredComponents.push(customComp);
      this.componentMap.set(customComp.id, arkComp);
    }
  }

  /**
   * 注销组件
   * @param component UIComponent
   */
  public unregisterComponent(customComp: UIComponent): void {
    const index = this.registeredComponents.indexOf(customComp);
    if (index >= 0) this.registeredComponents.splice(index, 1);
    this.componentMap.delete(customComp.id);
  }

  /** 动态更新组件（解注册后再注册） */
  public updateComponent(customComp: UIComponent, arkComp: ESObject): void {
    this.unregisterComponent(customComp);
    this.registerComponent(customComp, arkComp);
  }

  /**
   * 捕获所有注册组件快照
   * @returns SnapshotEventData[]
   */
  public async captureSnapshot(): Promise<SnapshotEventData[]> {
    const snapshots: SnapshotEventData[] = [];

    for (let i = 0; i < this.registeredComponents.length; i++) {
      const comp: UIComponent = this.registeredComponents[i];
      const arkComp = this.componentMap.get(comp.id);

      if (!arkComp) continue;

      try {
        class ViewRenderAttrs { op: string; componentId: string; constructor(op: string, id: string){ this.op = op; this.componentId = id; } }
        const span = new SpanTimer('view.render', new ViewRenderAttrs('render.component', comp.id) as Object);
        // ArkUI 截图逻辑
        const pixelMap = await arkComp.renderToPixelMap();
        const imageInfo = pixelMap.getImageInfo();
        const width: number = (await imageInfo).size.width;
        const height: number = (await imageInfo).size.height;

        const arr: Uint8Array = new Uint8Array(pixelMap.getPixelBytesNumber() as number);
        pixelMap.readPixelsToBuffer(arr.buffer);

        let imageBase64: string = this.arrayBufferToBase64(arr);

        // 基于组件粒度的遮罩：若该组件应遮罩，则改写为空白像素图
        if (this.privacy.shouldMaskComponent(comp.id) || this.privacy.isMaskAllImages()) {
          const masked = new Uint8Array(arr.length);
          imageBase64 = this.arrayBufferToBase64(masked);
        }

        snapshots.push({
          componentId: comp.id,
          imageBase64,
          width,
          height
        });
        class ViewRenderEnd { width: number; height: number; constructor(w: number, h: number){ this.width = w; this.height = h; } }
        TraceManager.get().addSpan(span.end(new ViewRenderEnd(width, height) as Object));
      } catch (e) {
        console.error(`捕获组件快照失败: ${comp.id}`, e);
      }
    }

    return snapshots;
  }

  /**
   * ArrayBuffer / Uint8Array 转 Base64
   */
  private arrayBufferToBase64(bytes: Uint8Array): string {
    let binary: string = '';
    for (let i: number = 0; i < bytes.byteLength; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    return globalThis.btoa(binary);
  }
}

