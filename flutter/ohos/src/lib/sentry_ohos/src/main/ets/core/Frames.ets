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

import { Breadcrumb, SentryLevel } from '../sentry/Breadcrumb';
import { TraceManager } from './TraceManager';

type Primitive = string | number | boolean | null | undefined;

export interface FramesSnapshot {
  total: number;
  slow: number;
  frozen: number;
}

export interface FramesMonitorOptions {
  slowFrameThresholdMs: number; // e.g. 48ms
  frozenFrameThresholdMs: number; // e.g. 700ms
  sampleRate: number; // 0..1
}

export class FramesMonitor {
  private opts: FramesMonitorOptions;
  private running: boolean = false;
  private lastTickMs: number | undefined;
  private timerId: number | undefined;
  private total: number = 0;
  private slow: number = 0;
  private frozen: number = 0;
  private onBreadcrumb?: (b: Breadcrumb) => void;

  constructor(opts: FramesMonitorOptions, onBreadcrumb?: (b: Breadcrumb) => void) {
    this.opts = opts;
    this.onBreadcrumb = onBreadcrumb;
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    const tickInterval = 16; // ~60fps
    const setIntervalTyped = (setInterval as (handler: () => void, timeout?: number) => number);
    this.lastTickMs = Date.now();
    this.timerId = setIntervalTyped(() => {
      const now = Date.now();
      const last = this.lastTickMs !== undefined ? this.lastTickMs : now;
      const delta = now - last; // ms since last tick
      this.lastTickMs = now;
      // 统计一帧（按 tick 粗测）
      this.total++;
      // 判断 slow/frozen
      if (delta >= this.opts.frozenFrameThresholdMs) {
        this.frozen++;
        this.emitFrameBreadcrumb('frozen', delta);
      } else if (delta >= this.opts.slowFrameThresholdMs) {
        this.slow++;
        this.emitFrameBreadcrumb('slow', delta);
      }
    }, tickInterval);
  }

  stop(): void {
    if (!this.running) return;
    this.running = false;
    if (this.timerId !== undefined) {
      try {
        const clearIntervalTyped = (clearInterval as (handle: number) => void);
        clearIntervalTyped(this.timerId);
      } catch (_) {}
      this.timerId = undefined;
    }
  }

  snapshotAndReset(): FramesSnapshot {
    const out: FramesSnapshot = { total: this.total, slow: this.slow, frozen: this.frozen };
    this.total = 0;
    this.slow = 0;
    this.frozen = 0;
    return out;
  }

  private emitFrameBreadcrumb(kind: 'slow' | 'frozen', deltaMs: number): void {
    // 采样
    const r = this.opts.sampleRate;
    if (typeof r === 'number') {
      if (r <= 0) return;
      if (r < 1.0) {
        const roll = Math.random();
        if (roll > r) return;
      }
    }
    if (!this.onBreadcrumb) return;
    const bc = new Breadcrumb();
    bc.timestamp = new Date().toISOString();
    bc.message = kind === 'frozen' ? 'Frozen frame' : 'Slow frame';
    bc.category = 'ui.frame';
    bc.level = kind === 'frozen' ? SentryLevel.Error : SentryLevel.Warning;
    const rec: Record<string, string> = {};
    rec['frame_kind'] = kind;
    rec['duration_ms'] = String(deltaMs);
    bc.data = rec;
    this.onBreadcrumb(bc);
  }
}


