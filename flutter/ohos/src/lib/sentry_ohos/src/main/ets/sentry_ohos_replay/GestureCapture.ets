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

import { BaseUIEvent } from './BaseUIEvent';
import { UIComponent } from './Component';
import { ReplayEvent, TouchEventData } from './ReplayEvent';
import { TapEventData, LongPressEventData, PanEventData, PinchEventData, RotateEventData, SwipeEventData } from './ReplayEvent';
import { SentryOhos } from '../core/SentryOhos';
import { Breadcrumb as CoreBreadcrumb, SentryLevel } from '../sentry/Breadcrumb';

// ArkTS 要求对象字面量对应显式类型，定义 UI 点击数据接口
interface UIClickData { label: string }

interface PointerState {
  startX: number;
  startY: number;
  startTime: number;
  moved: boolean;
  longPressed: boolean;
  timerId?: number;
  lastX?: number;
  lastY?: number;
}

/**
 * GestureCapture
 * - 根据 down/move/up/longPress 判定 Click / Swipe / Move / LongPress
 * - 保存 UserActionEvent 队列，供上报/回放使用
 */
export class GestureCapture {
  private components: UIComponent[];
  private events: ReplayEvent[] = [];
  private stateMap: Map<string, PointerState> = new Map(); // key = `${component.id}:${pointerId}`
  private handlers: Map<string, (e: BaseUIEvent) => void> = new Map(); // 保存 handler 以便解绑
  private isCapturing: boolean = false;

  // 可配置阈值
  private longPressTimeout: number = 500; // ms，长按阈值
  private moveThreshold: number = 20;     // px，超过此位移视为移动/滑动

  constructor(components: UIComponent[], longPressTimeout?: number, moveThreshold?: number) {
    this.components = components;
    if (longPressTimeout !== undefined) this.longPressTimeout = longPressTimeout;
    if (moveThreshold !== undefined) this.moveThreshold = moveThreshold;
  }

  /** 开始捕获：为每个组件注册 onTouch 监听 */
  public startCapture(): void {
    this.isCapturing = true;
    this.components.forEach((comp) => {
      const handler = (event: BaseUIEvent) => this.handleTouchEvent(comp, event);
      comp.onTouch(handler);
      this.handlers.set(comp.id, handler);
      // 尝试绑定 ArkUI 官方手势（若适配层实现了这些可选接口）
      try {
        if (comp.onTap) comp.onTap((x: number, y: number) => {
          const data: TapEventData = { componentId: comp.id, x, y };
          this.pushEvent({ type: 'tap', timestamp: Date.now(), data });
        });
        if (comp.onLongPress) comp.onLongPress((x: number, y: number, d?: number) => {
          const data: LongPressEventData = { componentId: comp.id, x, y, durationMs: d };
          this.pushEvent({ type: 'longpress', timestamp: Date.now(), data });
        });
        if (comp.onPan) comp.onPan((dx: number, dy: number, vx?: number, vy?: number) => {
          const data: PanEventData = { componentId: comp.id, dx, dy, velocityX: vx, velocityY: vy };
          this.pushEvent({ type: 'pan', timestamp: Date.now(), data });
        });
        if (comp.onPinch) comp.onPinch((scale: number, cx?: number, cy?: number) => {
          const data: PinchEventData = { componentId: comp.id, scale, centerX: cx, centerY: cy };
          this.pushEvent({ type: 'pinch', timestamp: Date.now(), data });
        });
        if (comp.onRotate) comp.onRotate((angle: number, cx?: number, cy?: number) => {
          const data: RotateEventData = { componentId: comp.id, angle, centerX: cx, centerY: cy };
          this.pushEvent({ type: 'rotate', timestamp: Date.now(), data });
        });
        if (comp.onSwipe) comp.onSwipe((direction) => {
          const data: SwipeEventData = { componentId: comp.id, direction };
          this.pushEvent({ type: 'swipe', timestamp: Date.now(), data });
        });
      } catch (_) {}
    });
  }

  /** 停止捕获：尝试解绑监听并清理定时器 */
  public stopCapture(): void {
    this.isCapturing = false;
    this.handlers.forEach((handler, compId) => {
      const comp = this.components.find(c => c.id === compId);
      if (comp && comp.offTouch) {
        comp.offTouch(handler);
      }
      try {
        if (comp && comp.offTap && comp.onTap) comp.offTap((() => {}) as (x: number, y: number) => void);
        if (comp && comp.offLongPress && comp.onLongPress) comp.offLongPress((() => {}) as (x: number, y: number, d?: number) => void);
        if (comp && comp.offPan && comp.onPan) comp.offPan((() => {}) as (dx: number, dy: number, vx?: number, vy?: number) => void);
        if (comp && comp.offPinch && comp.onPinch) comp.offPinch((() => {}) as (scale: number, cx?: number, cy?: number) => void);
        if (comp && comp.offRotate && comp.onRotate) comp.offRotate((() => {}) as (angle: number, cx?: number, cy?: number) => void);
        if (comp && comp.offSwipe && comp.onSwipe) comp.offSwipe((() => {}) as (direction: 'Left' | 'Right' | 'Up' | 'Down') => void);
      } catch (_) {}
    });
    this.handlers.clear();

    // 清理所有未完成的 longPress 定时器
    this.stateMap.forEach((st) => {
      if (st.timerId !== undefined) {
        clearTimeout(st.timerId);
      }
    });
    this.stateMap.clear();
  }

  /** 返回已捕获事件（浅拷贝） */
  public getCapturedEvents(): ReplayEvent[] {
    return [...this.events];
  }

  /** 清空已捕获事件 */
  public clearEvents(): void {
    this.events = [];
  }

  /** 仅保留 cutoff 之后的事件，用于缓冲窗口裁剪 */
  public rotate(cutoffMs: number): void {
    this.events = this.events.filter(e => e.timestamp >= cutoffMs);
  }

  /** 动态添加/移除组件监听 */
  public addComponent(comp: UIComponent): void {
    this.components.push(comp);
    if (this.isCapturing) {
      const handler = (event: BaseUIEvent) => this.handleTouchEvent(comp, event);
      comp.onTouch(handler);
      this.handlers.set(comp.id, handler);
    }
  }

  public removeComponent(compId: string): void {
    const idx = this.components.findIndex(c => c.id === compId);
    if (idx >= 0) this.components.splice(idx, 1);
    const handler = this.handlers.get(compId);
    if (handler) {
      const comp = this.components.find(c => c.id === compId);
      if (comp && comp.offTouch) {
        comp.offTouch(handler);
      }
      this.handlers.delete(compId);
    }
  }

  /** 内部：处理 touch 事件并分类 */
  private handleTouchEvent(component: UIComponent, event: BaseUIEvent): void {
    const pointerId: number = event.pointerId ?? 0;
    const key = `${component.id}:${pointerId}`;
    const now = Date.now();
    const x = event.x ?? 0;
    const y = event.y ?? 0;

    switch (event.type) {
      case "down": {
        const st: PointerState = { startX: x, startY: y, startTime: now, moved: false, longPressed: false, lastX: x, lastY: y };
        st.timerId = setTimeout(() => {
          st.longPressed = true;
          this.pushEvent({
            type: "touch",
            timestamp: Date.now(),
            data: { componentId: component.id, x: st.lastX ?? x, y: st.lastY ?? y, action: "longPress" } as TouchEventData
          });
        }, this.longPressTimeout);
        this.stateMap.set(key, st);
        this.pushEvent({ type: "touch", timestamp: now, data: { componentId: component.id, x, y, action: "down" } as TouchEventData });
        break;
      }

      case "move": {
        const st = this.stateMap.get(key);
        if (!st) return;
        const dx = x - st.startX;
        const dy = y - st.startY;
        if (!st.moved && Math.sqrt(dx*dx + dy*dy) >= this.moveThreshold) {
          st.moved = true;
          if (st.timerId) { clearTimeout(st.timerId); st.timerId = undefined; }
        }
        this.pushEvent({ type: "touch", timestamp: now, data: { componentId: component.id, x, y, action: "move" } as TouchEventData });
        st.lastX = x;
        st.lastY = y;

        break;
      }

      case "up": {
        const st = this.stateMap.get(key);
        if (st && st.timerId) { clearTimeout(st.timerId); st.timerId = undefined; }
        this.pushEvent({ type: "touch", timestamp: now, data: { componentId: component.id, x, y, action: "up" } as TouchEventData });
        // 判定为点击（无显著移动且未触发长按）时，记录 UI Click 面包屑
        try {
          if (st && !st.moved && !st.longPressed) {
            const bc = new CoreBreadcrumb();
            bc.timestamp = new Date().toISOString();
            bc.message = 'UI Click';
            bc.category = 'ui.click';
            bc.level = SentryLevel.Info;
            const data: UIClickData = { label: component.id };
            // 显式构造 Record<string, string>，避免 unknown/any 与未声明字面量
            const rec: Record<string, string> = {};
            rec['label'] = data.label;
            bc.data = rec;
            SentryOhos.addBreadcrumb(bc);
          }
        } catch (_) {}
        if (st) this.stateMap.delete(key);
        break;

      }

      case "longPress": {
        break;
      }
    }
  }

  /** 将内部事件压入队列 */
  private pushEvent(evt: ReplayEvent): void {
    this.events.push(evt);
    // 这里可替换为 Logger、或触发回调、或立即写入缓存；为保持通用性只入队
  }
}
