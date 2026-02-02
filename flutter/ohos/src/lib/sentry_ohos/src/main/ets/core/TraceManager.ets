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

import { SentryTransaction, TransactionMeasurement } from '../sentry/SentryEvent';
import { Span as SdkSpan } from '../sentry/Span';
import { SpanContext } from './Performance';

interface TransactionMeasurementEntry { value: number; unit?: string }

class TransactionMeasurements {
  private store: Record<string, TransactionMeasurementEntry> = {};
  set(key: string, value: TransactionMeasurementEntry): void {
    this.store[key] = value;
  }
  get(key: string): TransactionMeasurementEntry | undefined {
    return this.store[key];
  }
  keys(): Array<string> { return Object.keys(this.store); }
  toRecord(): Record<string, TransactionMeasurementEntry> { return this.store; }
}

interface ActiveTransaction {
  name: string;
  op: string;
  traceId: string;
  rootSpanId: string;
  startedMs: number;
  timeoutMs: number;
  timerId?: number;
  txn: SentryTransaction;
  meas: TransactionMeasurements;
}

export interface TransactionHandle {
  traceId: string;
  spanId: string;
  name: string;
  op: string;
  startedMs: number;
}

class TraceContextObj {
  trace_id?: string;
  span_id?: string;
  op?: string;
  origin?: string;
  status?: string;
}

export interface TraceSnapshot { trace_id: string; span_id: string; op: string; status: string }

export class TraceManager {
  private static _instance: TraceManager | undefined;
  static get(): TraceManager {
    if (!TraceManager._instance) TraceManager._instance = new TraceManager();
    return TraceManager._instance as TraceManager;
  }

  private active?: ActiveTransaction;
  private external?: TraceSnapshot;

  startTransaction(name: string, op: string, timeoutMs: number = 10000, autoCommitEnabled: boolean = true): TransactionHandle {
    this.abort();
    const traceId = this.generateHexId(32);
    const rootSpanId = this.generateHexId(16);
    const txn = new SentryTransaction(name);
    const nowIso = new Date().toISOString();
    // contexts.trace
    const t = new TraceContextObj();
    t.trace_id = traceId;
    t.span_id = rootSpanId;
    t.op = op;
    t.origin = 'manual';
    t.status = 'unknown';
    txn.contexts['trace'] = t as Object;
    const startedMs = Date.now();
    const act: ActiveTransaction = { name, op, traceId, rootSpanId, startedMs, timeoutMs, txn, meas: new TransactionMeasurements() };
    // 自动提交定时器：仅在启用时设置
    if (autoCommitEnabled) {
      const tid = setTimeout(async () => {
        try {
          const txn = this.commit();
          if (txn) {
            type AutoCommitHook = (t: SentryTransaction) => Promise<void>;
            interface TMWithHook { onAutoCommit?: AutoCommitHook }
            const self: TMWithHook = TraceManager as TMWithHook;
            if (typeof self.onAutoCommit === 'function') {
              await self.onAutoCommit(txn);
            }
          }
        } catch (_) {}
      }, timeoutMs);
      act.timerId = Number(tid);
    } else {
      act.timerId = undefined;
    }
    this.active = act;
    const handle: TransactionHandle = { traceId: traceId, spanId: rootSpanId, name: name, op: op, startedMs: startedMs };
    return handle;
  }

  addSpan(ctx: SpanContext): void {
    if (!this.active) return;
    const act = this.active;
    const traceId = act.traceId;
    const parentId = act.rootSpanId;
    const spanId = this.generateHexId(16);
    const startIso = ctx.startMs !== undefined ? new Date(ctx.startMs).toISOString() : new Date().toISOString();
    const endIso = ctx.endMs !== undefined ? new Date(ctx.endMs).toISOString() : undefined;
    interface AttrsKnown { op?: string; status?: string }
    const known = (ctx.attrs as AttrsKnown | undefined);
    const op: string = (known && typeof known.op === 'string') ? (known.op as string) : 'default';
    const sp = new SdkSpan(traceId, spanId, startIso);
    sp.op = op;
    sp.description = ctx.name;
    sp.end_timestamp = endIso;
    sp.parent_span_id = parentId;
    // status/data：从 attrs 映射
    if (known && typeof known.status === 'string') sp.status = known.status as string;
    act.txn.spans.push(sp);
  }

  commit(): SentryTransaction | undefined {
    if (!this.active) return undefined;
    const act = this.active;
    // 取消定时器
    if (act.timerId !== undefined) {
      try { clearTimeout(act.timerId); } catch (_) {}
      act.timerId = undefined;
    }
    const txn = act.txn;
    // 写入 measurements
    const measKeys = act.meas.keys();
    for (let i = 0; i < measKeys.length; i++) {
      const k = measKeys[i];
      const m = act.meas.get(k);
      if (m) {
        txn.setMeasurement(k, m.value, m.unit);
      }
    }
    this.active = undefined;
    return txn;
  }

  abort(): void {
    if (!this.active) return;
    const act = this.active;
    if (act.timerId !== undefined) {
      try { clearTimeout(act.timerId); } catch (_) {}
    }
    this.active = undefined;
  }

  hasActive(): boolean { return !!this.active; }

  getActiveTraceSnapshot(): TraceSnapshot | undefined {
    const act = this.active;
    if (act) {
      const snap: TraceSnapshot = { trace_id: act.traceId, span_id: act.rootSpanId, op: act.op, status: 'unknown' };
      return snap;
    }
    if (this.external) return this.external;
    return undefined;
  }

  // 提供只读活跃 spans，避免外部通过 unknown/any 访问私有字段
  getActiveSpans(): Array<SdkSpan> | null {
    const act = this.active;
    if (act && act.txn && Array.isArray(act.txn.spans)) {
      return act.txn.spans as Array<SdkSpan>;
    }
    return null;
  }

  setExternalTrace(snapshot: TraceSnapshot): void {
    this.external = snapshot;
  }

  addMeasurement(key: string, value: number, unit?: string): void {
    if (!this.active) return;
    const u = this.normalizeUnit(unit);
    this.active.meas.set(key, { value: value, unit: u });
  }

  private normalizeUnit(unit?: string): string | undefined {
    if (!unit) return undefined;
    const raw = unit.trim();
    if (raw.length === 0) return undefined;
    const u = raw.toLowerCase();
    // duration
    if (u === 'ms' || u === 'millisecond' || u === 'milliseconds') return 'millisecond';
    if (u === 's' || u === 'sec' || u === 'second' || u === 'seconds') return 'second';
    if (u === 'us' || u === 'µs' || u === 'microsecond' || u === 'microseconds') return 'microsecond';
    if (u === 'ns' || u === 'nanosecond' || u === 'nanoseconds') return 'nanosecond';
    if (u === 'm' || u === 'min' || u === 'minute' || u === 'minutes') return 'minute';
    if (u === 'h' || u === 'hour' || u === 'hours') return 'hour';
    // information (decimal)
    if (u === 'b' || u === 'bit' || u === 'bits') return 'bit';
    if (u === 'byte' || u === 'bytes' || u === 'btye') return 'byte';
    if (u === 'kb' || u === 'kilobyte' || u === 'kilobytes') return 'kilobyte';
    if (u === 'mb' || u === 'megabyte' || u === 'megabytes') return 'megabyte';
    if (u === 'gb' || u === 'gigabyte' || u === 'gigabytes') return 'gigabyte';
    // information (binary IEC)
    if (u === 'kib' || u === 'kibibyte' || u === 'kibibytes') return 'kibibyte';
    if (u === 'mib' || u === 'mebibyte' || u === 'mebibytes') return 'mebibyte';
    if (u === 'gib' || u === 'gibibyte' || u === 'gibibytes') return 'gibibyte';
    // frequency
    if (u === 'hz' || u === 'hertz') return 'hz';
    if (u === 'khz' || u === 'kilohertz') return 'kilohertz';
    if (u === 'mhz' || u === 'megahertz') return 'megahertz';
    if (u === 'ghz' || u === 'gigahertz') return 'gigahertz';
    // percent
    if (u === '%' || u === 'percent' || u === 'percentage' || u === 'pct') return 'percent';
    // generic count
    if (u === 'item' || u === 'items' || u === 'count') return 'item';
    return unit; // fallback: keep original
  }

  private generateHexId(len: number): string {
    const hex = '0123456789abcdef';
    let out = '';
    for (let i = 0; i < len; i++) {
      const n = Math.floor(Math.random() * 16);
      out += hex.charAt(n);
    }
    return out;
  }
}


