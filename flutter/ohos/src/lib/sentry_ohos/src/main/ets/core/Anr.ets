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

import { Breadcrumb } from '../sentry/Breadcrumb';
import { nowMs } from './HarmonyUtilsAdapter';

export interface AnrEvent {
  timestamp: string;
  blockedForMs: number;
  isInForeground?: boolean;
  lastBreadcrumb?: Breadcrumb;
  threads?: Array<AnrThread>;
}

export interface AnrThread {
  name: string;
  state: string;
}

export class AnrMonitor {
  private lastBeatMs: number = nowMs();
  private thresholdMs: number;
  private onAnr: (e: AnrEvent) => void | Promise<void>;
  private timer: number | undefined;
  private nextExpectedMs: number | undefined;
  private running: boolean = false;

  constructor(thresholdMs: number, onAnr: (e: AnrEvent) => void | Promise<void>) {
    this.thresholdMs = thresholdMs;
    this.onAnr = onAnr;
  }

  beat(): void {
    // 静默记录心跳，减少日志输出（只在debug模式或异常时输出）
    this.lastBeatMs = nowMs();
  }

  // 手动记录心跳（供外部调用）
  beatManual(): void {
    this.beat();
  }

  startTicker(intervalMs: number): void {
    if (this.running) return;
    this.running = true;
    // release 关闭启动日志
    const tick = () => {
      const now = nowMs();
      if (this.nextExpectedMs !== undefined) {
        const driftMs = now - this.nextExpectedMs;
        if (driftMs >= this.thresholdMs) {
          const evt: AnrEvent = { timestamp: new Date().toISOString(), blockedForMs: driftMs };
          this.onAnr(evt);
        }
        // 静默更新心跳（不输出日志）
      }
      // 更新心跳与下一次期望时间
      this.lastBeatMs = now;
      this.nextExpectedMs = now + intervalMs;
    };
    // 立即设定下一次期望时间，并启动周期检测
    this.nextExpectedMs = nowMs() + intervalMs;
    // ArkTS/JS 环境中 setInterval 返回 number，保存以便 stop 使用
    // 注意：这是辅助检测，主要依赖系统hiAppEvent Watcher
    const setIntervalTyped = (setInterval as (handler: () => void, timeout?: number) => number);
    this.timer = setIntervalTyped(tick, intervalMs);
  }

  check(): void {
    try {
      const now = nowMs();
      const diff = now - this.lastBeatMs;
      if (diff >= this.thresholdMs) {
        try {
          const evt: AnrEvent = { timestamp: new Date().toISOString(), blockedForMs: diff };
          // 立即触发回调，不等待结果（因为可能异步且应用可能崩溃）
          try {
            const result = this.onAnr(evt);
            // 如果回调返回 Promise，处理它但不阻塞
            if (result && typeof (result as Promise<void>).catch === 'function') {
              (result as Promise<void>).catch((err: Error | Object) => {
                console.error(`[Sentry] AnrMonitor onAnr callback promise rejected: ${err}`);
              });
            }
          } catch (syncErr) {
            console.error(`[Sentry] AnrMonitor onAnr callback threw synchronously: ${syncErr}`);
          }
          // 重置以避免重复
          this.lastBeatMs = nowMs();
        } catch (err) {
          console.error(`[Sentry] AnrMonitor ERROR in ANR event creation/callback: ${err}`);
        }
      }
    } catch (err) {
      console.error(`[Sentry] AnrMonitor FATAL ERROR in check() method: ${err}`);
    }
  }

  stop(): void {
    if (!this.running) return;
    this.running = false;
    if (this.timer !== undefined) {
      try {
        const clearIntervalTyped = (clearInterval as (handle: number) => void);
        clearIntervalTyped(this.timer);
      } catch (_) {
      }
      this.timer = undefined;
    }
    this.nextExpectedMs = undefined;
  }
}




