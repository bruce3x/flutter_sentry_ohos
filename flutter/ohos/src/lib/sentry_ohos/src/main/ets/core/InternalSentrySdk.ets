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

import { Sentry } from '../sentry/Sentry';
import { Hub } from '../sentry/Hub';
import { Scope } from '../sentry/Scope';
import { Breadcrumb } from '../sentry/Breadcrumb';
import { SentryEvent, SentryTransaction } from '../sentry/SentryEvent';
import { SentryEnvelope, SentryEnvelopeHeader, SentryEnvelopeItem } from '../sentry/SentryEnvelope';
import { SdkVersion } from '../sentry/SdkVersion';
import { HttpTransport } from '../sentry/HttpTransport';
import { Envelope as CoreEnvelope } from './Types';
import util from '@ohos.util';
import { TraceManager } from './TraceManager';
import fs from '@ohos.file.fs';
import fileio from '@ohos.fileio';
import { User } from '../sentry/User';
import { SentryLevel } from '../sentry/SentryLevel';
import { SentryId } from '../sentry/SentryId';
import { collectDeviceContext } from './Context';
import { Installation } from './Installation';

type Primitive = string | number | boolean | null | undefined;

// Harmony 对齐 Android InternalSentrySdk：提供对外内部静态包装，便于统一调用
// 提前声明 Envelope 输出头与条目头类型，避免函数内联类型
interface SdkHeaderOut { name: string; version: string }

interface EnvelopeHeaderOut {
  sent_at: string;
  event_id?: string;
  dsn?: string;
  sdk?: SdkHeaderOut;
}
interface EnvelopeItemHeaderOut { type: string; length: number }

export class InternalSentrySdk {
  // 获取当前 Scope（克隆），与 Android getCurrentScope 对齐的简化版
  static getCurrentScope(): Scope | null {
    const hub = Sentry.getHub();
    try {
      const scope = hub.getScope();
      return scope ? scope.clone() : null;
    } catch (_) {
      return null;
    }
  }
  static getCurrentHub(): Hub {
    return Sentry.getHub();
  }

  // Harmony 版 Hub 无 withScope/configureScope，提供等效包装：直接把当前 scope 传入回调
  static withScope(callback: (scope: Scope) => void): void {
    const hub = Sentry.getHub();
    const scope = hub.getScope();
    callback(scope);
  }

  static configureScope(callback: (scope: Scope) => void): void {
    const hub = Sentry.getHub();
    const scope = hub.getScope();
    callback(scope);
  }

  static async captureMessage(message: string, level?: SentryLevel): Promise<void> {
    const hub = Sentry.getHub();
    if (level !== undefined) hub.setLevel(level);
    await hub.captureMessage(message);
  }

  static async captureException(error: Error): Promise<void> {
    await Sentry.getHub().captureException(error);
  }

  static async captureEvent(event: SentryEvent): Promise<void> {
    await Sentry.getHub().captureEvent(event);
  }

  static async captureTransaction(tx: SentryTransaction): Promise<void> {
    await Sentry.getHub().captureTransaction(tx);
  }

  static addBreadcrumb(breadcrumb: Breadcrumb): void {
    Sentry.getHub().addBreadcrumb(breadcrumb);
  }

  static clearBreadcrumbs(): void {
    Sentry.getHub().clearBreadcrumbs();
  }

  static setTag(key: string, value: string): void {
    Sentry.getHub().setTag(key, value);
  }

  static removeTag(key: string): void {
    Sentry.getHub().removeTag(key);
  }

  static setExtra(key: string, value: Object): void {
    Sentry.getHub().setExtra(key, value);
  }

  static removeExtra(key: string): void {
    Sentry.getHub().removeExtra(key);
  }

  static setUser(user: User): void {
    Sentry.getHub().setUser(user);
  }

  static setContext(key: string, value: Object): void {
    Sentry.getHub().setContext(key, value);
  }

  static removeContext(key: string): void {
    Sentry.getHub().removeContext(key);
  }

  static setLevel(level: SentryLevel | undefined): void {
    Sentry.getHub().setLevel(level);
  }

  static setTransaction(name: string | undefined): void {
    Sentry.getHub().setTransaction(name);
  }

  static setFingerprint(list: Array<string> | undefined): void {
    Sentry.getHub().setFingerprint(list);
  }

  static startSession(): void {
    Sentry.startSession();
  }

  static endSession(): void {
    Sentry.endSession();
  }

  static getLastEventId(): string | undefined {
    const id = Sentry.getLastEventId();
    return id === null ? undefined : id;
  }

  // 序列化 Scope：输出 user/contexts/tags/extras/fingerprint/level/breadcrumbs
  static serializeScope(scope: Scope | null): Object {
    class SerializedScope {
      user?: User;
      contexts?: Record<string, Object | null>;
      tags?: Record<string, string | null>;
      extras?: Record<string, Object | null>;
      fingerprint?: Array<string>;
      level?: SentryLevel;
      breadcrumbs?: Array<Breadcrumb>;
    }
    const out = new SerializedScope();
    if (scope === null) return out as Object;
    try {
      const user = scope.user || new User();
      // 对齐 Android：如果没有 user.id，自动填充 Installation ID
      if (!user.id) {
        user.id = Installation.id();
      }
      out.user = user;
      out.contexts = scope.contexts;
      out.tags = scope.tags;
      out.extras = scope.extra;
      if (scope.fingerprint) out.fingerprint = scope.fingerprint;
      if (scope.level !== undefined) out.level = scope.level;
      out.breadcrumbs = scope.breadcrumbs;
    } catch (_) {
      const empty = new SerializedScope();
      return empty as Object;
    }
    return out as Object;
  }

  // 对齐 Android InternalSentrySdk.captureEnvelope：
  // 重新打包为标准 Envelope 文本（header\nitemHeader\npayload\n...），再交由 Transport 发送
  static async captureEnvelope(envelope: SentryEnvelope): Promise<boolean> {
    const hub = Sentry.getHub();
    const transport = hub.transport as HttpTransport | null;
    if (!transport) return false;
    try {
      const serialized: string = InternalSentrySdk.buildEnvelopeText(envelope);
      const encoder = new util.TextEncoder();
      const bytes = encoder.encode(serialized);
      return await transport.sendRawEnvelope(bytes);
    } catch (_) {
      return false;
    }
  }

  // Envelope 序列化（遵循 Sentry 协议）
  private static buildEnvelopeText(env: SentryEnvelope): string {
    const headerIn: SentryEnvelopeHeader = env.header as SentryEnvelopeHeader;
    const outHeader: EnvelopeHeaderOut = {
      sent_at: new Date().toISOString(),
    };
    if (headerIn) {
      if (typeof headerIn.eventId === 'string' && headerIn.eventId.length > 0) outHeader.event_id = headerIn.eventId;
      if (typeof headerIn.dsn === 'string' && headerIn.dsn.length > 0) outHeader.dsn = headerIn.dsn;
      const sdkIn = headerIn.sdk as SdkVersion | undefined;
      if (sdkIn && typeof sdkIn.name === 'string' && typeof sdkIn.version === 'string') {
        outHeader.sdk = { name: sdkIn.name, version: sdkIn.version };
      }
    }
    let text = JSON.stringify(outHeader) + "\n";

    const items: Array<SentryEnvelopeItem> = env.items as Array<SentryEnvelopeItem>;
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      const payload: string = typeof it.payload === 'string' ? it.payload : '';
      const itemHeader: EnvelopeItemHeaderOut = { type: it.type, length: payload.length };
      text += JSON.stringify(itemHeader) + "\n" + payload + "\n";
    }
    return text;
  }

  // 将 core 层 Envelope 结构转换为 SentryEnvelope，并直接发送
  static async captureCoreEnvelope(env: CoreEnvelope): Promise<boolean> {
    try {
      // 简化：将 core Envelope 直接 JSON 序列化发送，类型标识映射为 envelope item.type
      const hub = Sentry.getHub();
      const transport = hub.transport as HttpTransport | null;
      if (!transport) {
        console.error(`[Sentry] InternalSentrySdk ERROR: transport is null`);
        return false;
      }
      try {
        interface EnvelopeHeader { sent_at: string }
        interface EnvelopeItemHeader { type: string; length: number }
        const headerObj: EnvelopeHeader = { sent_at: env.timestamp };
        const payloadStr: string = JSON.stringify(env);
        const itemHeader: EnvelopeItemHeader = { type: env.type, length: payloadStr.length };
        const serialized: string = `${JSON.stringify(headerObj)}\n${JSON.stringify(itemHeader)}\n${payloadStr}`;
        const encoder = new util.TextEncoder();
        const bytes = encoder.encode(serialized);
        const result = await transport.sendRawEnvelope(bytes);
        return result;
      } catch (err) {
        console.error(`[Sentry] InternalSentrySdk ERROR in envelope serialization/send: ${err}`);
        return false;
      }
    } catch (err) {
      console.error(`[Sentry] InternalSentrySdk FATAL ERROR in captureCoreEnvelope: ${err}`);
      return false;
    }
  }

  // AppStart measurement：从 SentryOhos 的 AppStartMonitor 提供简化视图
  static getAppStartMeasurement(): Object {
    class AppStartSpan { description?: string; start_timestamp_ms?: number; end_timestamp_ms?: number }
    class AppStartOut { spans: Array<AppStartSpan> = []; type: string = 'cold'; app_start_timestamp_ms?: number }
    const spans: Array<AppStartSpan> = [];
    try {
      // 依赖 SentryOhos 的 _appStart 采集点（已在 SentryOhos 中记录）
      // 这里仅返回 cold start 的聚合信息（描述、起止时间）
      // Harmony 暂无对应全部节点，提供最小可用集
    } catch (_) {}
    const out = new AppStartOut();
    out.spans = spans;
    out.type = 'cold';
    return out as Object;
  }

  // 对齐 Android：设置 Trace（供混合 SDK 透传）
  static setTrace(traceId: string, spanId: string, sampleRate?: number, sampleRand?: number): void {
    // Harmony 侧将外部 trace 记为 external snapshot，供异常或事件上下文读取
    const tm = TraceManager.get();
    const rate = typeof sampleRate === 'number' ? sampleRate : undefined;
    const rand = typeof sampleRand === 'number' ? sampleRand : undefined;
    // 仅存储必要字段；sampleRate/sampleRand 可后续用于采样判定（目前占位）
    class Snap { trace_id: string = ''; span_id: string = ''; op: string = ''; status: string = '' }
    const snap = new Snap();
    snap.trace_id = traceId;
    snap.span_id = spanId;
    snap.op = 'external';
    snap.status = 'unknown';
    try {
      // 使用公开方法设置外部 trace
      tm.setExternalTrace({ trace_id: snap.trace_id, span_id: snap.span_id, op: snap.op, status: snap.status });
    } catch (_) {}
  }

  // 对齐 Android：captureEnvelope(byte[], boolean) → 返回 SentryId
  static async captureEnvelopeBytes(envelopeData: Uint8Array, maybeStartNewSession: boolean): Promise<SentryId> {
    try {
      if (maybeStartNewSession === true) {
        try { InternalSentrySdk.startSession(); } catch (_) {}
      }
      // 解析 envelope（二进制安全）以提取 event_id，并在调试模式下转储 PNG 附件
      type JsonRecord = Record<string, string | number | boolean | object | null | undefined>;
      const readLineEnd = (buf: Uint8Array, start: number): number => {
        const len = buf.byteLength;
        let i = start;
        while (i < len) { if (buf[i] === 0x0A) return i; i++; }
        return -1;
      };
      const decodeAscii = (buf: Uint8Array, s: number, e: number): string => {
        let out = '';
        for (let i = s; i < e; i++) out += String.fromCharCode(buf[i] & 0xFF);
        return out;
      };
      const toHex = (u8: Uint8Array, n: number): string => {
        const hex: Array<string> = [];
        const m = Math.min(n, u8.byteLength);
        for (let i = 0; i < m; i++) {
          const v = u8[i] & 0xFF; const h = v.toString(16).toUpperCase(); hex.push(h.length === 1 ? ('0' + h) : h);
        }
        return hex.join(' ');
      };
      let eventIdStr: string | undefined = undefined;
      // 仅在 Sentry 处于 debug=true 时启用二次转储
      const hubDbg = Sentry.getHub().getOptions().debug === true;
      if (hubDbg) try {
        let pos = 0;
        const hEnd = readLineEnd(envelopeData, pos);
        const headerStr = hEnd >= 0 ? decodeAscii(envelopeData, pos, hEnd) : decodeAscii(envelopeData, 0, envelopeData.byteLength);
        pos = hEnd >= 0 ? (hEnd + 1) : envelopeData.byteLength;
        try {
          const headerObj = JSON.parse(headerStr) as Record<string, string>;
          const eid = headerObj && typeof headerObj['event_id'] === 'string' ? headerObj['event_id'] : undefined;
          if (eid && eid.length > 0) eventIdStr = eid;
        } catch (_) {}
        // 遍历 items，定位首个 image/png 附件
        while (pos < envelopeData.byteLength) {
          const itemHdrEnd = readLineEnd(envelopeData, pos);
          if (itemHdrEnd < 0) break;
          const itemHdrStr = decodeAscii(envelopeData, pos, itemHdrEnd);
          pos = itemHdrEnd + 1;
          let typeVal: string | undefined = undefined;
          let lengthVal: number = 0;
          try {
            const itemObj = JSON.parse(itemHdrStr) as JsonRecord;
            typeVal = (itemObj['type'] as string | undefined);
            const lv = itemObj['length'] as number | undefined; lengthVal = (typeof lv === 'number' && lv > 0) ? Math.floor(lv) : 0;
          } catch (_) { break; }
          let contentType: string | undefined = undefined;
          let metaStr: string | undefined = undefined;
          if (typeVal === 'attachment') {
            const metaEnd = readLineEnd(envelopeData, pos);
            if (metaEnd > pos) {
              metaStr = decodeAscii(envelopeData, pos, metaEnd);
              pos = metaEnd + 1;
              try {
                const metaObj = JSON.parse(metaStr) as JsonRecord;
                contentType = (metaObj['content_type'] as string | undefined) || (metaObj['contentType'] as string | undefined);
              } catch (_) {
                // meta 非 JSON，视为 payload 起点
              }
            }
          }
          if (typeVal === 'attachment' && contentType === 'image/png') {
            const start = pos;
            const end = Math.min(pos + lengthVal, envelopeData.byteLength);
            const body = envelopeData.subarray(start, end);
            try {
              const head32 = toHex(body, 32);
              const tail = body.byteLength >= 16 ? body.subarray(body.byteLength - 16) : body;
              const tailHex = toHex(tail, tail.byteLength);
              const hasIEND = body.byteLength >= 12 && body[body.byteLength - 12] === 0x00 && body[body.byteLength - 11] === 0x00 && body[body.byteLength - 10] === 0x00 && body[body.byteLength - 9] === 0x00 && body[body.byteLength - 8] === 0x49 && body[body.byteLength - 7] === 0x45 && body[body.byteLength - 6] === 0x4E && body[body.byteLength - 5] === 0x44 && body[body.byteLength - 4] === 0xAE && body[body.byteLength - 3] === 0x42 && body[body.byteLength - 2] === 0x60 && body[body.byteLength - 1] === 0x82;
              console.info('[SentryDump2] png len=' + String(body.byteLength) + ' head32=' + head32 + ' tail16=' + tailHex + ' iend=' + String(hasIEND));
              // 将 PNG 落盘以便人工验证
              const dumpDir = '/data/storage/el2/base/haps/entry/files/sentry';
              try {
                const st = fs.statSync(dumpDir);
                if (!st.isDirectory()) { fs.mkdirSync(dumpDir); }
              } catch (_) { try { fs.mkdirSync(dumpDir); } catch (_) {} }
              const eidPart = eventIdStr && eventIdStr.length > 0 ? eventIdStr : 'noeid';
              const name = `${dumpDir}/png_dump_${eidPart}_${Date.now()}.png`;
              const O_CREAT = 0o100; const O_TRUNC = 0o1000; const O_WRONLY = 0o1;
              const fd = fileio.openSync(name, O_CREAT | O_TRUNC | O_WRONLY, 0o666);
              const written = fileio.writeSync(fd, body);
              try { fileio.closeSync(fd); } catch (_) {}
              console.info('[SentryDump2] png_dump path=' + name + ' written=' + String(typeof written === 'number' ? written : 0));
            } catch (e) {
              console.error('[SentryDump2] dump png failed ' + (e?.message || ''));
            }
            break; // 仅 dump 第一个 PNG 附件
          }
          // 跳过 payload + LF（若存在）
          pos = pos + lengthVal;
          if (pos < envelopeData.byteLength && envelopeData[pos] === 0x0A) pos += 1;
        }
      } catch (e) {
        console.error('[SentryDump2] parse envelope failed ' + (e?.message || ''));
      }

      // 🔍 解析 envelope 并注入完整设备上下文
      let enrichedBytes = envelopeData;
      try {
        enrichedBytes = InternalSentrySdk.enrichEnvelopeWithDeviceContext(envelopeData);
      } catch (e) {
        console.error('[enrichEnvelope] FAILED: ' + (e?.message || String(e)));
        // 失败时回退到原始 envelope
        enrichedBytes = envelopeData;
      }

      const hub = Sentry.getHub();
      const transport = hub.transport as HttpTransport | null;
      if (!transport) return SentryId.empty();
      const ok = await transport.sendRawEnvelope(enrichedBytes);
      if (ok) {
        return eventIdStr ? SentryId.fromId(eventIdStr) : SentryId.empty();
      }
      return SentryId.empty();
    } catch (_) {
      return SentryId.empty();
    }
  }

  // 解析 envelope 并注入完整设备上下文
  private static enrichEnvelopeWithDeviceContext(envelopeBytes: Uint8Array): Uint8Array {
    const readLineEnd = (buf: Uint8Array, start: number): number => {
      const len = buf.byteLength;
      let i = start;
      while (i < len) { if (buf[i] === 0x0A) return i; i++; }
      return -1;
    };
    const decodeAscii = (buf: Uint8Array, s: number, e: number): string => {
      let out = '';
      for (let i = s; i < e; i++) out += String.fromCharCode(buf[i] & 0xFF);
      return out;
    };
    const encodeUtf8 = (str: string): Uint8Array => {
      const arr: Array<number> = [];
      for (let i = 0; i < str.length; i++) arr.push(str.charCodeAt(i) & 0xFF);
      return new Uint8Array(arr);
    };

    try {
      // 1) 解析 envelope header
      let pos = 0;
      const headerEnd = readLineEnd(envelopeBytes, pos);
      const headerStr = headerEnd >= 0 ? decodeAscii(envelopeBytes, pos, headerEnd) : '';
      pos = headerEnd >= 0 ? (headerEnd + 1) : envelopeBytes.byteLength;

      // 2) 收集设备上下文
      const deviceCtx = collectDeviceContext();
      const deviceKeys = Object.keys(deviceCtx);
      console.info('[enrichEnvelope] collected ' + deviceKeys.length + ' device fields');

      // 3) 解析 event item 并注入设备上下文
      while (pos < envelopeBytes.byteLength) {
        const itemHdrEnd = readLineEnd(envelopeBytes, pos);
        if (itemHdrEnd < 0) break;
        const itemHdrStr = decodeAscii(envelopeBytes, pos, itemHdrEnd);
        pos = itemHdrEnd + 1;

        let eventObj: Record<string, Object> | null = null;
        let lengthVal = 0;
        try {
          const itemHdrObj = JSON.parse(itemHdrStr) as Record<string, Primitive>;
          const typeVal = (itemHdrObj['type'] as string | undefined);
          if (typeVal === 'event') {
            lengthVal = (typeof itemHdrObj['length'] === 'number' && itemHdrObj['length'] > 0) ? Math.floor(itemHdrObj['length'] as number) : 0;
            const payloadStart = pos;
            const payloadEnd = Math.min(payloadStart + lengthVal, envelopeBytes.byteLength);
            const payloadStr = decodeAscii(envelopeBytes, payloadStart, payloadEnd);
            eventObj = JSON.parse(payloadStr) as Record<string, Object>;

            // 注入设备上下文
            if (!eventObj['contexts']) {
              const emptyContexts: Record<string, Object> = {};
              (eventObj as Record<string, Object>)['contexts'] = emptyContexts as Object;
            }
            const contexts = (eventObj['contexts'] as Record<string, Object>);
            const deviceObj: Record<string, Object> = {};
            for (let i = 0; i < deviceKeys.length; i++) {
              const key = deviceKeys[i];
              if (deviceCtx[key] !== undefined) {
                deviceObj[key] = deviceCtx[key] as Object;
              }
            }
            contexts['device'] = deviceObj as Object;

            // Inject release/environment/dist from SDK options if event has null values
            try {
              const hub = Sentry.getHub();
              const options = hub.getOptions();
              if (options) {
                // release: inject if event has null/undefined
                if ((eventObj['release'] === null || eventObj['release'] === undefined) && typeof options.release === 'string' && options.release.length > 0) {
                  eventObj['release'] = options.release as Object;
                }
                // environment: inject if event has null/undefined
                if ((eventObj['environment'] === null || eventObj['environment'] === undefined) && typeof options.environment === 'string' && options.environment.length > 0) {
                  eventObj['environment'] = options.environment as Object;
                }
                // dist: inject if event has null/undefined
                if ((eventObj['dist'] === null || eventObj['dist'] === undefined) && typeof options.dist === 'string' && options.dist.length > 0) {
                  eventObj['dist'] = options.dist as Object;
                }
              }
            } catch (e) {
              console.error('[enrichEnvelope] inject release/env/dist failed: ' + (e?.message || String(e)));
            }

            // 重新序列化 envelope
            const enrichedPayload = JSON.stringify(eventObj);
            const enrichedPayloadBytes = encodeUtf8(enrichedPayload);
            const newHeader = encodeUtf8('{"type":"event","length":' + enrichedPayloadBytes.byteLength + '}\n');
            const newPayload = new Uint8Array(newHeader.byteLength + enrichedPayloadBytes.byteLength + 1);
            let destOffset = 0;
            newPayload.set(newHeader, destOffset); destOffset += newHeader.byteLength;
            newPayload.set(enrichedPayloadBytes, destOffset); destOffset += enrichedPayloadBytes.byteLength;
            newPayload[destOffset] = 0x0A; // LF

            // 查找原始 item 的边界
            const itemHdrStart = pos - itemHdrStr.length - 1; // item header 开始
            let originalItemEnd = payloadEnd; // payload 结束
            if (originalItemEnd < envelopeBytes.byteLength && envelopeBytes[originalItemEnd] === 0x0A) {
              originalItemEnd += 1; // 包括 LF
            }

            // 拼接：原始到item开始 + 新item + item结束后的剩余
            const totalLen = itemHdrStart + newPayload.byteLength + (envelopeBytes.byteLength - originalItemEnd);
            const result = new Uint8Array(totalLen);
            let offset = 0;
            result.set(envelopeBytes.subarray(0, itemHdrStart), offset); offset += itemHdrStart;
            result.set(newPayload, offset); offset += newPayload.byteLength;
            result.set(envelopeBytes.subarray(originalItemEnd), offset);

            return result;
          }
        } catch (e) {
          console.error('[enrichEnvelope] parse failed: ' + (e?.message || String(e)));
          break;
        }

        // 跳过当前 item
        if (lengthVal > 0) {
          pos = pos + lengthVal;
          if (pos < envelopeBytes.byteLength && envelopeBytes[pos] === 0x0A) pos += 1;
        }
      }
    } catch (e) {
      console.error('[enrichEnvelope] enrichment failed: ' + (e?.message || String(e)));
    }

    // 回退到原始 envelope
    return envelopeBytes;
  }
}


