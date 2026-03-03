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

import { ITransport } from './Transport';
import { SentryBaseEvent, SentryEvent, SentryTransaction, SentryReplayEvent } from './SentryEvent';
import { SentryException } from './SentryException';
import { SentryMessage } from './SentryMessage';
import { SentryLevel } from './SentryLevel';
import { Breadcrumb } from './Breadcrumb';
import http from '@ohos.net.http';
import { SentryOptions } from './SentryOptions';
import { FileEnvelopeCache, CachedRawEnvelope } from './Cache';
import { ClientReport, ClientReportPayload } from './ClientReport';
import { SentryThread } from './SentryThread';
import { SdkVersion } from './SdkVersion';
import fs from '@ohos.file.fs';
import fileio from '@ohos.fileio';
import util from '@ohos.util';
import { UserFeedbackPayload } from './UserFeedback';
import { getReplayId } from '../sentry_ohos_replay/api';
import { replayInfo } from '../sentry_ohos_replay/ReplayLogger';

// Types for serialization outputs
interface MessageOut { message: string }
interface BreadcrumbOut { timestamp?: string; message?: string; category?: string; level?: string; type?: string; data?: Record<string, string> }
interface ErrorLike { message?: string; code?: string | number }
interface ErrorMsgLike { message?: string }

interface EnvelopeHeader {
  sent_at: string;
  // 如果需要可以扩展 sdk: { name: string; version: string } 等字段
}

// 顶层声明，避免在函数体内声明内联接口触发 ArkTS 规则
export interface EnvelopeHeaderExt extends EnvelopeHeader { event_id?: string }
export interface AttachmentSpec { filePath: string; filename: string; contentType: string; attachmentType?: string; maxBytes?: number }
interface AttachmentMeta { filename: string; content_type: string; attachment_type: string }

interface EnvelopeItemHeader {
  type: string;
  length: number;
}

// 响应最小头部类型（用于解析限流头）
interface HttpResponseWithHeaders {
  header?: Record<string, string>;
}

// 兼容 OpenHarmony HttpResponse 头部可能为广义 object 的情况
interface HttpResponsePossiblyHasHeader {
  responseCode: number;
  result?: string;
  header?: object;
}

export class HttpTransport implements ITransport {
  private options: SentryOptions;
  private client: http.HttpRequest = http.createHttp();
  private cache: FileEnvelopeCache | null = null;
  private clientReport: ClientReport | null = null;
  private rateLimitUntilMs: number | null = null;
  private isFlushing: boolean = false; // Flush lock to prevent concurrent execution

  private endpoint: string;

  constructor(options: SentryOptions,cache: FileEnvelopeCache | null = null, clientReport: ClientReport | null = null) {
    this.options = options;
    this.cache = cache;
    this.clientReport = clientReport;
    this.endpoint = this.buildEndpointFromDsn(options.dsn);
  }

  // 二进制换行符（LF）
  private static readonly LF: Uint8Array = new Uint8Array([0x0A]);

  // 将字符串以 UTF-8 编码为字节（避免依赖 TextEncoder）
  private encodeUtf8(input: string): Uint8Array {
    const bytes: Array<number> = [];
    for (let i = 0; i < input.length; i++) {
      let codePoint = input.charCodeAt(i);
      if (codePoint >= 0xD800 && codePoint <= 0xDBFF && i + 1 < input.length) {
        const next = input.charCodeAt(i + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          codePoint = ((codePoint - 0xD800) << 10) + (next - 0xDC00) + 0x10000;
          i++;
        }
      }
      if (codePoint <= 0x7F) {
        bytes.push(codePoint);
      } else if (codePoint <= 0x7FF) {
        bytes.push(0xC0 | (codePoint >> 6));
        bytes.push(0x80 | (codePoint & 0x3F));
      } else if (codePoint <= 0xFFFF) {
        bytes.push(0xE0 | (codePoint >> 12));
        bytes.push(0x80 | ((codePoint >> 6) & 0x3F));
        bytes.push(0x80 | (codePoint & 0x3F));
      } else {
        bytes.push(0xF0 | (codePoint >> 18));
        bytes.push(0x80 | ((codePoint >> 12) & 0x3F));
        bytes.push(0x80 | ((codePoint >> 6) & 0x3F));
        bytes.push(0x80 | (codePoint & 0x3F));
      }
    }
    const out = new Uint8Array(bytes.length);
    for (let j = 0; j < bytes.length; j++) out[j] = bytes[j];
    return out;
  }

  // 计算字符串的 UTF-8 字节长度（用于 Envelope 协议 length 字段）
  private getUtf8ByteLength(input: string): number {
    return this.encodeUtf8(input).byteLength;
  }

  // 将字节按 ASCII/UTF-8 简单解码为字符串（用于日志）
  private decodeAscii(buf: Uint8Array): string {
    try {
      let out = '';
      for (let i = 0; i < buf.byteLength; i++) out += String.fromCharCode(buf[i] & 0xFF);
      return out;
    } catch (_) {
      return '';
    }
  }

  // 打印 envelope（字节）预览：逐行打印头与首个条目（避免过长被截断）
  private logEnvelopePreviewFromBytes(envelopeBytes: Uint8Array, tag: string): void {
    try {
      const text = this.decodeAscii(envelopeBytes);
      this.logEnvelopePreviewFromString(text, tag);
    } catch (_) {}
  }

  // 打印 envelope（字符串）预览：头、第一条 item 头、payload 前 2000 字符
  private logEnvelopePreviewFromString(text: string, tag: string): void {
    // 调试日志已移除
  }

  // 附件项头（包含文件元信息）
  private buildAttachmentHeader(length: number, filename: string, contentType: string, attachmentType?: string): Uint8Array {
    class AttachmentItemHeader { type: string; length: number; filename: string; content_type: string; attachment_type: string;
      constructor(len: number, fn: string, ct: string, at?: string) { this.type = 'attachment'; this.length = len; this.filename = fn; this.content_type = ct; this.attachment_type = at && at.length > 0 ? at : 'event.attachment'; } }
    const obj = new AttachmentItemHeader(length, filename, contentType, attachmentType);
    return this.encodeUtf8(JSON.stringify(obj));
  }

  // 显式读取可选 dist 字段，避免使用 unknown 或索引签名
  private getDist(): string | undefined {
    interface OptionsWithDist { dist?: string }
    const o = this.options as OptionsWithDist;
    return typeof o.dist === 'string' ? o.dist : undefined;
  }

  // 显式实现 Base64 编码，避免使用类型未知的全局 btoa
  private encodeBase64(bytes: Uint8Array): string {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let output = '';
    let i = 0;
    while (i + 2 < bytes.length) {
      const b0 = dv.getUint8(i);
      const b1 = dv.getUint8(i + 1);
      const b2 = dv.getUint8(i + 2);
      const n = (b0 << 16) | (b1 << 8) | b2;
      output += chars.charAt((n >> 18) & 63) + chars.charAt((n >> 12) & 63) + chars.charAt((n >> 6) & 63) + chars.charAt(n & 63);
      i += 3;
    }
    const remain = bytes.length - i;
    if (remain === 1) {
      const b0 = dv.getUint8(i);
      const n = b0 << 16;
      output += chars.charAt((n >> 18) & 63) + chars.charAt((n >> 12) & 63) + '==';
    } else if (remain === 2) {
      const b0 = dv.getUint8(i);
      const b1 = dv.getUint8(i + 1);
      const n = (b0 << 16) | (b1 << 8);
      output += chars.charAt((n >> 18) & 63) + chars.charAt((n >> 12) & 63) + chars.charAt((n >> 6) & 63) + '=';
    }
    return output;
  }

  public setClientReport(report: ClientReport): void { this.clientReport = report; }

  // 发送用户反馈（与事件解耦，可使用最近一次 eventId）
  public async sendUserFeedback(payload: UserFeedbackPayload): Promise<void> {
    try {
      const header: EnvelopeHeader = { sent_at: new Date().toISOString() };
      const itemHeader: EnvelopeItemHeader = { type: 'user_report', length: this.getUtf8ByteLength(JSON.stringify(payload)) };
      const envelope = `${JSON.stringify(header)}\n${JSON.stringify(itemHeader)}\n${JSON.stringify(payload)}\n`;
      await this.client.request(this.endpoint, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/x-sentry-envelope', 'User-Agent': 'sentry.harmony.ets/0.1.0' },
        connectTimeout: 10000,
        extraData: envelope,
      });
    } catch (_) {}
  }

  private static normalizeReplayId(id: string): string {
    const out: Array<string> = [];
    let acc = 0;
    for (let i = 0; i < id.length; i++) {
      acc = (acc * 131 + (id.charCodeAt(i) & 0xFFFF)) >>> 0;
      const h = (acc & 0xFF).toString(16);
      out.push(h.length === 1 ? ('0' + h) : h);
      if (out.length >= 32) break;
    }
    while (out.length < 32) out.push('0');
    return out.join('').slice(0, 32).toLowerCase();
  }

  async send(event: SentryBaseEvent): Promise<boolean> {
    try {
      const eventType = event instanceof SentryTransaction ? 'transaction' : (event instanceof SentryReplayEvent ? 'replay' : 'event');
      // no-op log in release
    } catch (_) {}
    if (this.isRateLimited()) {

      if (this.cache) {
        this.cache.store(event);

      }
      if (this.clientReport) this.clientReport.addDiscardedEvent('rate_limit', 'event', 1);
      return false;
    }
    const url = this.endpoint;

    // 在传输层最终兜底：注入 replayId 到 tags/contexts（若可用）
    try {
      let rid: string | undefined = undefined;
      try { rid = getReplayId(); } catch (_) { rid = undefined; }
      if (typeof rid === 'string' && rid.length > 0) {
        const ridNorm = HttpTransport.normalizeReplayId(rid);
        const ev: SentryEvent = event as SentryEvent;
        const tags: Record<string, string> = (ev.tags || {}) as Record<string, string>;
        tags['replayId'] = ridNorm;
        ev.tags = tags;
        const ctx: Record<string, Object> = (ev.contexts || {}) as Record<string, Object>;
        class ReplayCtx { replay_id?: string; id?: string; type?: string; constructor(id: string) { this.replay_id = id; this.id = id; this.type = 'replay'; } }
        ctx['replay'] = new ReplayCtx(ridNorm) as Object;
        (ev as SentryEvent).contexts = ctx;
        if (this.options.debug) {
          replayInfo('HttpTransport', 'transport inject rid=' + ridNorm + ' into event');
        }
      }
    } catch (_) {}
    const envelope = this.buildEnvelope(event);


    try {
      const result = await this.client.request(
        url,
        {
          method: http.RequestMethod.POST,
          header: {
            'Content-Type': 'application/x-sentry-envelope',
            'User-Agent': 'sentry.harmony.ets/0.1.0'
          },
          connectTimeout: 10000,
          extraData: envelope,
        });
      if (result.responseCode >= 200 && result.responseCode < 300) {

        if (this.options.debug) {
          console.info(`[Sentry] [HttpTransport] Success: ${result.responseCode}`);
        }
        return true;
      } else {
        if (result.responseCode === 429) {
          const headers = this.coerceHeaders((result as HttpResponsePossiblyHasHeader).header);
          this.applyRateLimitFromHeaders({ header: headers });
        }

        if (this.cache) {
          this.cache.store(event); // 写入缓存

        }
        if (this.clientReport) this.clientReport.addDiscardedEvent(result.responseCode === 429 ? 'rate_limit' : 'network_error', 'event', 1);
        return false;
      }
    } catch (err) {
      const em = ((): string => {
        const maybe = err as ErrorLike;
        const msg = typeof maybe?.message === 'string' ? maybe.message : String(err);
        const code = (maybe && (typeof maybe.code === 'string' || typeof maybe.code === 'number')) ? String(maybe.code) : '';
        return code ? `${msg} - ${code}` : msg;
      })();
      console.error(`[Sentry] HttpTransport send exception: ${em}`);
      if (this.cache) {
        this.cache.store(event);

      }
      if (this.clientReport) this.clientReport.addDiscardedEvent('network_error', 'event', 1);
      return false;
    }
  }

  // 一次 Envelope 内同时发送事件和多个附件，使用同一个 event_id 绑定（与 Android 抓包对齐）
  public async sendEventWithAttachments(event: SentryBaseEvent, attachments: Array<AttachmentSpec>): Promise<boolean> {
    if (this.isRateLimited()) {
      if (this.options.debug) console.warn('[Sentry] [HttpTransport] skip sendEventWithAttachments due to rate limit');
      if (this.cache) this.cache.store(event as SentryEvent);
      if (this.clientReport) this.clientReport.addDiscardedEvent('rate_limit', 'event', 1);
      return false;
    }
    // 传输层兜底：在带附件路径同样注入 replayId 至 tags/contexts
    try {
      let rid: string | undefined = undefined;
      try { rid = getReplayId(); } catch (_) { rid = undefined; }
      if (typeof rid === 'string' && rid.length > 0) {
        const ev: SentryEvent = event as SentryEvent;
        const tags: Record<string, string> = (ev.tags || {}) as Record<string, string>;
        tags['replayId'] = rid;
        ev.tags = tags;
        const ctx: Record<string, Object> = (ev.contexts || {}) as Record<string, Object>;
        class ReplayCtx { replay_id?: string; id?: string; type?: string; constructor(id: string) { this.replay_id = id; this.id = id; this.type = 'replay'; } }
        ctx['replay'] = new ReplayCtx(rid) as Object;
        ev.contexts = ctx;
        if (this.options.debug) {
          replayInfo('HttpTransport', 'transport inject rid=' + rid + ' into event(withAttachments)');
        }
      }
    } catch (_) {}

    // 1) 构造二进制 Envelope（header + event + 多个 attachment 原始字节）
    const parts: Array<Uint8Array> = [];
    const header: EnvelopeHeaderExt = { sent_at: new Date().toISOString() };
    // 仅当 event_id 合法（32位十六进制）时写入 envelope header
    try {
      const eid = event.event_id;
      if (typeof eid === 'string' && /^[0-9a-f]{32}$/.test(eid)) {
        header.event_id = eid;
      }
    } catch (_) {}
    const headerBytes: Uint8Array = this.encodeUtf8(JSON.stringify(header));
    parts.push(headerBytes); parts.push(HttpTransport.LF);
    const serialized = this.serializeEvent(event);
    const payloadStr: string = JSON.stringify(serialized);
    const payloadBytes: Uint8Array = this.encodeUtf8(payloadStr);
    const eventItemHeader: EnvelopeItemHeader = { type: 'event', length: payloadBytes.byteLength };
    parts.push(this.encodeUtf8(JSON.stringify(eventItemHeader))); parts.push(HttpTransport.LF);
    parts.push(payloadBytes); parts.push(HttpTransport.LF);
    // attachments（单行 header，直接包含 filename/content_type/attachment_type）
    for (let i = 0; i < attachments.length; i++) {
      try {
        const a = attachments[i];
        const st = fileio.statSync(a.filePath);
        const size = (st.size as number);
        let readSize = size;
        if (typeof a.maxBytes === 'number' && a.maxBytes > 0 && readSize > a.maxBytes) readSize = a.maxBytes;
        const O_RDONLY = 0o0; // read-only
        const fd = fileio.openSync(a.filePath, O_RDONLY);
        const ab = new ArrayBuffer(readSize);
        const n = fileio.readSync(fd, ab);
        fileio.closeSync(fd);
        const buf = new Uint8Array(ab, 0, n > 0 ? n : 0);
        // PNG 健壮性修正（发送前再次兜底）：
        // 1) 修正 IHDR length 8..11 字节
        // 2) 修正可能被 0x20 污染的宽高高位字节（16..23）
        try {
          if (buf.byteLength >= 24) {
            const sigOk = (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4E && buf[3] === 0x47 && buf[4] === 0x0D && buf[5] === 0x0A && buf[6] === 0x1A && buf[7] === 0x0A);
            const ihdr = (buf[12] === 0x49 && buf[13] === 0x48 && buf[14] === 0x44 && buf[15] === 0x52);
            if (sigOk && ihdr) {
              if (buf[8] === 0x20 || buf[9] === 0x20 || buf[10] === 0x20) {
                buf[8] = 0x00; buf[9] = 0x00; buf[10] = 0x00; buf[11] = 0x0D;
              }
              if (buf[16] === 0x20) buf[16] = 0x00;
              if (buf[17] === 0x20) buf[17] = 0x00;
              if (buf[20] === 0x20) buf[20] = 0x00;
              if (buf[21] === 0x20) buf[21] = 0x00;
            }
          }
        } catch (_) {}
        const itemHeaderBytes: Uint8Array = this.buildAttachmentHeader(buf.byteLength, a.filename, a.contentType, a.attachmentType);
        parts.push(itemHeaderBytes); parts.push(HttpTransport.LF);
        parts.push(buf); parts.push(HttpTransport.LF);
      } catch (_) {}
    }
    // 拼接为一个连续的 Uint8Array
    let total = 0;
    for (let pi = 0; pi < parts.length; pi++) total += parts[pi].byteLength;
    const envelopeBytes = new Uint8Array(total);
    let off = 0;
    for (let pi = 0; pi < parts.length; pi++) { envelopeBytes.set(parts[pi], off); off += parts[pi].byteLength; }
    // 2) 发送
    try {
      const result = await this.client.request(this.endpoint, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/x-sentry-envelope', 'User-Agent': 'sentry.harmony.ets/0.1.0' },
        connectTimeout: 10000,
        // Use a sliced ArrayBuffer to match the view range exactly
        extraData: envelopeBytes.buffer.slice(envelopeBytes.byteOffset, envelopeBytes.byteOffset + envelopeBytes.byteLength) as ArrayBuffer,
      });
      if (result.responseCode >= 200 && result.responseCode < 300) {
        if (this.options.debug) console.info('[Sentry] [HttpTransport] sendEventWithAttachments ok: ' + String(result.responseCode));
        return true;
      } else {
        if (result.responseCode === 429) {
          const headers = this.coerceHeaders((result as HttpResponsePossiblyHasHeader).header);
          this.applyRateLimitFromHeaders({ header: headers });
        }
        if (this.cache) this.cache.store(event as SentryEvent);
        if (this.clientReport) this.clientReport.addDiscardedEvent(result.responseCode === 429 ? 'rate_limit' : 'network_error', 'event', 1);
        return false;
      }
    } catch (err) {
      if (this.options.debug) console.error('[Sentry] [HttpTransport] sendEventWithAttachments exception');
      if (this.cache) this.cache.store(event as SentryEvent);
      if (this.clientReport) this.clientReport.addDiscardedEvent('network_error', 'event', 1);
      return false;
    }
  }

  // 直接发送 Flutter 侧序列化好的 envelope 原始字节，跳过本地序列化
  async sendRawEnvelope(envelopeBytes: Uint8Array): Promise<boolean> {
    try {
      if (this.isRateLimited()) {
        return false;
      }
      const url = this.endpoint;
      try {
        const result = await this.client.request(
          url,
          {
            method: http.RequestMethod.POST,
            header: {
              'Content-Type': 'application/x-sentry-envelope',
              'User-Agent': 'sentry.harmony.ets/0.1.0'
            },
            connectTimeout: 10000,
            // Use a sliced ArrayBuffer to match the view range exactly
            extraData: envelopeBytes.buffer.slice(envelopeBytes.byteOffset, envelopeBytes.byteOffset + envelopeBytes.byteLength) as ArrayBuffer,
          });
        if (result.responseCode >= 200 && result.responseCode < 300) {
          return true;
        } else {
          if (result.responseCode === 429) {
            const headers = this.coerceHeaders((result as HttpResponsePossiblyHasHeader).header);
            this.applyRateLimitFromHeaders({ header: headers });
          }
          console.error(`[Sentry] HttpTransport sendRaw failed: responseCode=${result.responseCode}`);
          // Cache the envelope for later retry (Android pattern)
          if (this.cache) {
            this.cache.storeRawEnvelope(envelopeBytes);
          }
          return false;
        }
      } catch (err) {
        // 提取详细的错误信息
        const em = ((): string => {
          const maybe = err as ErrorLike;
          const msg = typeof maybe?.message === 'string' ? maybe.message : (err instanceof Error ? err.message : String(err));
          const code = (maybe && (typeof maybe.code === 'string' || typeof maybe.code === 'number')) ? String(maybe.code) : '';
          const stack = (err instanceof Error && err.stack) ? err.stack : '';
          if (code && stack) {
            return `${msg} - ${code}\nStack: ${stack}`;
          } else if (code) {
            return `${msg} - ${code}`;
          } else if (stack) {
            return `${msg}\nStack: ${stack}`;
          }
          return msg;
        })();
        console.error(`[Sentry] HttpTransport sendRaw exception: ${em}`);
        // 尝试打印错误对象的 JSON（如果可能）
        try {
          if (typeof err === 'object' && err !== null) {
            const errObj = err as Record<string, Object>;
            const keys = Object.keys(errObj);
            if (keys.length > 0) {
              const errDetails: Array<string> = [];
              for (let i = 0; i < keys.length; i++) {
                const key = keys[i];
                const val = errObj[key];
                errDetails.push(`${key}=${String(val)}`);
              }
              console.error(`[Sentry] HttpTransport sendRaw exception properties: ${errDetails.join(', ')}`);
            }
          }
        } catch (_) {
          // 忽略 JSON 序列化错误
        }
        // Cache the envelope for later retry on network failure (Android pattern)
        if (this.cache) {
          this.cache.storeRawEnvelope(envelopeBytes);
        }
        return false;
      }
    } catch (err) {
      // 外层 catch：捕获整个函数中的未预期错误
      const em = ((): string => {
        const maybe = err as ErrorLike;
        const msg = typeof maybe?.message === 'string' ? maybe.message : (err instanceof Error ? err.message : String(err));
        const code = (maybe && (typeof maybe.code === 'string' || typeof maybe.code === 'number')) ? String(maybe.code) : '';
        return code ? `${msg} - ${code}` : msg;
      })();
      console.error(`[Sentry] HttpTransport FATAL ERROR in sendRawEnvelope: ${em}`);
      return false;
    }
  }

   // Sentry Envelope 协议
  private buildEnvelope(event: SentryBaseEvent): string {
    const txCandidate = event as SentryTransaction;
    if (txCandidate && typeof txCandidate.transaction === 'string') {
      const serialized = this.serializeEvent(event);
      const payload: string = JSON.stringify(serialized);
      const header: EnvelopeHeaderExt = { sent_at: new Date().toISOString() };
      try {
        const eid = event.event_id;
        if (typeof eid === 'string' && /^[0-9a-f]{32}$/.test(eid)) header.event_id = eid;
      } catch (_) {}
      const itemHeader: EnvelopeItemHeader = { type: 'transaction', length: this.getUtf8ByteLength(payload) };
      return `${JSON.stringify(header)}\n${JSON.stringify(itemHeader)}\n${payload}\n`;
    } else {
    const serialized = this.serializeEvent(event);
    const payload: string = JSON.stringify(serialized);
      const header: EnvelopeHeaderExt = { sent_at: new Date().toISOString() };
      try {
        const eid = event.event_id;
        if (typeof eid === 'string' && /^[0-9a-f]{32}$/.test(eid)) header.event_id = eid;
      } catch (_) {}
      const itemHeader: EnvelopeItemHeader = { type: 'event', length: this.getUtf8ByteLength(payload) };
      return `${JSON.stringify(header)}\n${JSON.stringify(itemHeader)}\n${payload}\n`;
    }
  }

  // 构造并发送附件（attachment item）
  public async sendAttachment(filePath: string, filename: string, contentType: string = 'text/plain', maxBytes?: number): Promise<void> {
    try {
      const st = fileio.statSync(filePath);
      const size = (st.size as number);
      let readSize = size;
      if (typeof maxBytes === 'number' && maxBytes > 0 && readSize > maxBytes) readSize = maxBytes;
      const O_RDONLY = 0o0; // read-only
      const fd = fileio.openSync(filePath, O_RDONLY);
      const ab = new ArrayBuffer(readSize);
      const n = fileio.readSync(fd, ab);
      fileio.closeSync(fd);
      const buf = new Uint8Array(ab, 0, n > 0 ? n : 0);
      // 将二进制内容转成 base64（Sentry attachment 支持 raw，但此处使用 base64 以简化跨端传输）
      const b64 = this.encodeBase64(buf);
      const header: EnvelopeHeader = { sent_at: new Date().toISOString() };
      const itemHeader: EnvelopeItemHeader = { type: 'attachment', length: b64.length };
      interface AttachmentMeta { filename: string; content_type: string; attachment_type: string }
      const meta: AttachmentMeta = { filename: filename, content_type: contentType, attachment_type: 'event.attachment' };
      const envelope = `${JSON.stringify(header)}\n${JSON.stringify(itemHeader)}\n${JSON.stringify(meta)}\n${b64}\n`;
      await this.client.request(this.endpoint, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/x-sentry-envelope', 'User-Agent': 'sentry.harmony.ets/0.1.0' },
        connectTimeout: 10000,
        extraData: envelope,
      });
    } catch (_) {}
  }

  // 发送 ClientReport（discarded_events）
  public async sendClientReport(): Promise<void> {
    if (!this.clientReport || !this.clientReport.hasItems()) return;
    const payloadObj: ClientReportPayload = this.clientReport.buildPayload();
    const payload: string = JSON.stringify(payloadObj);
    const header: EnvelopeHeader = { sent_at: new Date().toISOString() };
    // Sentry 协议：item type 为 'client_report'
    const itemHeader: EnvelopeItemHeader = { type: 'client_report', length: this.getUtf8ByteLength(payload) };
    const envelope = `${JSON.stringify(header)}\n${JSON.stringify(itemHeader)}\n${payload}\n`;
    try {
      await this.client.request(this.endpoint, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/x-sentry-envelope', 'User-Agent': 'sentry.harmony.ets/0.1.0' },
        connectTimeout: 10000,
        extraData: envelope,
      });
      this.clientReport.reset();
    } catch (_) {
      // 保留，下次 flush 再发
    }
  }

  // 将我们内部事件结构映射为 Sentry 期望的 JSON 结构
  private serializeEvent(ev: SentryBaseEvent): object {
    interface MechanismOut { type?: string; handled?: boolean }
    interface ExceptionValueOut { type?: string; value?: string; mechanism?: MechanismOut; stacktrace?: StackTraceOut; thread_id?: number }
    interface ExceptionWithThreadId { threadId?: number }
    interface ExceptionOut { values: Array<ExceptionValueOut> }
    interface MessageOut { message: string }
    interface BreadcrumbOut { timestamp?: string; message?: string; category?: string; level?: string; type?: string; data?: Record<string, string> }
    interface ThreadOut { id?: number; name?: string; priority?: number; state?: string; crashed?: boolean; current?: boolean; daemon?: boolean; main?: boolean; data?: Record<string, string>; stacktrace?: StackTraceOut; snapshot?: boolean }
    interface StackFrameOut { filename?: string; function?: string; module?: string; lineno?: number; colno?: number; abs_path?: string; in_app?: boolean; native?: boolean }
    interface StackTraceOut { frames: Array<StackFrameOut> }
    interface ThreadsOut { values: Array<ThreadOut> }
    interface SdkPackageOut { name?: string; version?: string }
    interface SdkOut { name?: string; version?: string; packages?: Array<SdkPackageOut> }
    interface MeasurementOut { value: number; unit?: string }
    interface OutEvent {
      event_id?: string;
      timestamp?: string;
      platform?: string;
      level?: string;
      message?: string | MessageOut;
      tags?: Record<string, string>;
      contexts?: object;
      breadcrumbs?: Array<BreadcrumbOut>;
      exception?: ExceptionOut;
      extra?: Record<string, string>;
      user?: object;
      release?: string;
      environment?: string;
      dist?: string;
      fingerprint?: Array<string>;
      threads?: ThreadsOut;
      sdk?: SdkOut;
      measurements?: Record<string, MeasurementOut>;
    }

    const out: OutEvent = {};
    // 仅当 event_id 合法（32位十六进制）时写入 payload
    try {
      const eid = ev.event_id;
      if (typeof eid === 'string' && /^[0-9a-f]{32}$/.test(eid)) {
        out.event_id = eid;
      }
    } catch (_) {}
    out.timestamp = ev.timestamp;
    // 与 Android 抓包更一致：统一使用 'other' 以便前端渲染风格接近
    out.platform = 'other';
    out.level = this.levelToString(ev.level);
    // message
    const evAsEvent: SentryEvent = ev as SentryEvent;
    const msg: SentryMessage | undefined = evAsEvent.message;
    if (msg && msg.message) out.message = msg.message;
    // tags
    out.tags = ev.tags;
    if (!out.tags) out.tags = {};
    // 对齐 Flutter 端：来源 flutter，环境 dart
    if (!out.tags['event.origin']) out.tags['event.origin'] = 'flutter';
    if (!out.tags['event.environment']) out.tags['event.environment'] = 'dart';
    // 从异常/上下文派生更多 tags，贴近 Android 输出
    try {
      const evEvent = ev as SentryEvent;
      if (evEvent.exceptions && evEvent.exceptions.length > 0) {
        const first = evEvent.exceptions[0];
        if (first.mechanism && typeof first.mechanism.type === 'string') out.tags['mechanism'] = first.mechanism.type;
        if (first.mechanism && typeof first.mechanism.handled === 'boolean') out.tags['handled'] = first.mechanism.handled ? 'yes' : 'no';
      }
    } catch (_) {}
    // contexts：对常见上下文进行规范化映射（贴近 Android/Java 序列化字段）
    const ctxOut: Record<string, Object> = {};
    // 透传已有 contexts（作为基础）
    const srcCtx = ev.contexts as Record<string, Object>;
    const baseKeys = Object.keys(srcCtx);
    for (let bi = 0; bi < baseKeys.length; bi++) {
      const k = baseKeys[bi];
      const v = srcCtx[k];
      ctxOut[k] = v;
    }
    // 设备上下文标准化（camelCase → snake_case）
    interface DeviceCtxInCamel { manufacturer?: string; brand?: string; family?: string; model?: string; modelId?: string; arch?: string; archs?: Array<string>; chipset?: string; batteryLevel?: number; isCharging?: boolean; isOnline?: boolean; orientation?: string; simulator?: boolean; memorySize?: number; freeMemory?: number; storageSize?: number; freeStorage?: number; screenDensity?: number; screenDpi?: number; bootTime?: string; timezone?: string; id?: string; locale?: string; connectionType?: string; batteryTemperature?: number; processorCount?: number; processorFrequency?: number }
    type PrimitiveOut = string | number | boolean;
    const devRaw = srcCtx['device'] as DeviceCtxInCamel;
    interface RuntimeCtxCamel { screenWidthPx?: number; screenHeightPx?: number; batteryLevel?: number; isCharging?: boolean; online?: boolean; memoryTotalMb?: number; memoryUsedMb?: number; freeMemoryMb?: number; storageTotalGb?: number; storageFreeGb?: number; networkType?: string; screenDpi?: number; screenDensity?: number; lowMemory?: boolean; arch?: string; cpuFrequencyMHz?: number }
    const runtimeRaw = srcCtx['runtime'] as RuntimeCtxCamel;
    if (devRaw) {
      const d: Record<string, Object> = {};
      if (typeof devRaw.manufacturer === 'string') d['manufacturer'] = devRaw.manufacturer;
      if (typeof devRaw.brand === 'string') d['brand'] = devRaw.brand;
      if (typeof devRaw.family === 'string') d['family'] = devRaw.family;
      if (typeof devRaw.model === 'string') d['model'] = devRaw.model;
      if (typeof devRaw.modelId === 'string') d['model_id'] = devRaw.modelId;
      if (typeof devRaw.arch === 'string') d['arch'] = devRaw.arch;
      if (Array.isArray(devRaw.archs)) d['archs'] = devRaw.archs as Object;
      if (typeof devRaw.chipset === 'string') d['chipset'] = devRaw.chipset;
      if (typeof devRaw.batteryLevel === 'number') d['battery_level'] = devRaw.batteryLevel;
      if (typeof devRaw.isCharging === 'boolean') d['charging'] = devRaw.isCharging;
      if (typeof devRaw.isOnline === 'boolean') d['online'] = devRaw.isOnline;
      if (typeof devRaw.orientation === 'string') d['orientation'] = devRaw.orientation;
      if (typeof devRaw.simulator === 'boolean') d['simulator'] = devRaw.simulator;
      if (typeof devRaw.memorySize === 'number') d['memory_size'] = devRaw.memorySize;
      if (typeof devRaw.freeMemory === 'number') d['free_memory'] = devRaw.freeMemory;
      if (typeof devRaw.storageSize === 'number') d['storage_size'] = devRaw.storageSize;
      if (typeof devRaw.freeStorage === 'number') d['free_storage'] = devRaw.freeStorage;
      if (typeof devRaw.screenDensity === 'number') d['screen_density'] = devRaw.screenDensity;
      if (typeof devRaw.screenDpi === 'number') d['screen_dpi'] = devRaw.screenDpi;
      // 从 runtime 合并屏幕宽高像素（如有）
      if (runtimeRaw) {
        const sw = runtimeRaw.screenWidthPx;
        const sh = runtimeRaw.screenHeightPx;
        if (typeof sw === 'number') d['screen_width_pixels'] = sw;
        if (typeof sh === 'number') d['screen_height_pixels'] = sh;
        // battery/online from runtime
        if (typeof runtimeRaw.batteryLevel === 'number' && d['battery_level'] === undefined) d['battery_level'] = runtimeRaw.batteryLevel as Object;
        if (typeof runtimeRaw.isCharging === 'boolean' && d['charging'] === undefined) d['charging'] = runtimeRaw.isCharging as Object;
        if (typeof runtimeRaw.online === 'boolean' && d['online'] === undefined) d['online'] = runtimeRaw.online as Object;
        // memory (bytes)
        if (typeof runtimeRaw.memoryTotalMb === 'number' && d['memory_size'] === undefined) d['memory_size'] = Math.floor(runtimeRaw.memoryTotalMb * 1024 * 1024) as Object;
        if (typeof runtimeRaw.memoryTotalMb === 'number' && typeof runtimeRaw.memoryUsedMb === 'number' && d['free_memory'] === undefined) {
          const freeMb = runtimeRaw.memoryTotalMb - runtimeRaw.memoryUsedMb;
          if (freeMb >= 0) d['free_memory'] = Math.floor(freeMb * 1024 * 1024) as Object;
        }
        if (typeof runtimeRaw.lowMemory === 'boolean' && d['low_memory'] === undefined) d['low_memory'] = runtimeRaw.lowMemory as Object;
        // storage (bytes)
        if (typeof runtimeRaw.storageTotalGb === 'number' && d['storage_size'] === undefined) d['storage_size'] = Math.floor(runtimeRaw.storageTotalGb * 1024 * 1024 * 1024) as Object;
        if (typeof runtimeRaw.storageFreeGb === 'number' && d['free_storage'] === undefined) d['free_storage'] = Math.floor(runtimeRaw.storageFreeGb * 1024 * 1024 * 1024) as Object;
        // screen dpi/density
        if (typeof runtimeRaw.screenDpi === 'number' && d['screen_dpi'] === undefined) d['screen_dpi'] = runtimeRaw.screenDpi as Object;
        if (typeof runtimeRaw.screenDensity === 'number' && d['screen_density'] === undefined) d['screen_density'] = runtimeRaw.screenDensity as Object;
        // connection type
        if (typeof runtimeRaw.networkType === 'string' && d['connection_type'] === undefined) d['connection_type'] = runtimeRaw.networkType as Object;
        // processor frequency
        if (typeof runtimeRaw.cpuFrequencyMHz === 'number' && d['processor_frequency'] === undefined) d['processor_frequency'] = runtimeRaw.cpuFrequencyMHz as Object;
        // derive orientation
        if (d['orientation'] === undefined) {
          const sw = runtimeRaw.screenWidthPx;
          const sh = runtimeRaw.screenHeightPx;
          if (typeof sw === 'number' && typeof sh === 'number') {
            d['orientation'] = (sw < sh ? 'portrait' : 'landscape') as Object;
          }
        }
      }
      if (typeof devRaw.bootTime === 'string') d['boot_time'] = devRaw.bootTime;
      if (typeof devRaw.timezone === 'string') d['timezone'] = devRaw.timezone;
      if (typeof devRaw.id === 'string') d['id'] = devRaw.id;
      if (typeof devRaw.locale === 'string') d['locale'] = devRaw.locale;
      if (typeof devRaw.connectionType === 'string') d['connection_type'] = devRaw.connectionType;
      if (typeof devRaw.batteryTemperature === 'number') d['battery_temperature'] = devRaw.batteryTemperature;
      if (typeof devRaw.processorCount === 'number') d['processor_count'] = devRaw.processorCount;
      if (typeof devRaw.processorFrequency === 'number') d['processor_frequency'] = devRaw.processorFrequency;
      // 将 Context.ets 以逗号拼接的 archs 转回数组（兼容历史）
      interface DeviceAnyArchs { archs?: Array<string> | string }
      const devAny = srcCtx['device'] as DeviceAnyArchs;
      const archsStr = devAny && typeof devAny.archs === 'string' ? (devAny.archs as string) : undefined;
      if (!d['archs'] && typeof archsStr === 'string') {
        const arr = archsStr.split(',');
        d['archs'] = arr as Object;
      }
      // 若仍无 archs，基于 runtime.arch 推断
      if (!d['archs'] && runtimeRaw && typeof runtimeRaw.arch === 'string') {
        const archList = runtimeRaw.arch === 'arm64' ? ['arm64-v8a','armeabi-v7a','armeabi'] : ['armeabi-v7a','armeabi'];
        d['archs'] = archList as Object;
      }
      // 兼容 snake_case 设备字段（若 camelCase 缺失）
      interface DeviceCtxInSnake { battery_level?: number; online?: boolean; connection_type?: string; memory_size?: number; free_memory?: number; storage_size?: number; free_storage?: number; screen_density?: number; screen_dpi?: number; boot_time?: string; timezone?: string; id?: string; locale?: string; processor_count?: number; processor_frequency?: number; battery_temperature?: number; chipset?: string }
      const devSnakeRaw = srcCtx['device'];
      const devSnake: DeviceCtxInSnake = devSnakeRaw as DeviceCtxInSnake;
      if (d['battery_level'] === undefined && typeof devSnake.battery_level === 'number') d['battery_level'] = devSnake.battery_level as number;
      if (d['online'] === undefined && typeof devSnake.online === 'boolean') d['online'] = devSnake.online as boolean;
      if (d['connection_type'] === undefined && typeof devSnake.connection_type === 'string') d['connection_type'] = devSnake.connection_type as string;
      if (d['memory_size'] === undefined && typeof devSnake.memory_size === 'number') d['memory_size'] = devSnake.memory_size as number;
      if (d['free_memory'] === undefined && typeof devSnake.free_memory === 'number') d['free_memory'] = devSnake.free_memory as number;
      if (d['storage_size'] === undefined && typeof devSnake.storage_size === 'number') d['storage_size'] = devSnake.storage_size as number;
      if (d['free_storage'] === undefined && typeof devSnake.free_storage === 'number') d['free_storage'] = devSnake.free_storage as number;
      if (d['screen_density'] === undefined && typeof devSnake.screen_density === 'number') d['screen_density'] = devSnake.screen_density as number;
      if (d['screen_dpi'] === undefined && typeof devSnake.screen_dpi === 'number') d['screen_dpi'] = devSnake.screen_dpi as number;
      if (d['boot_time'] === undefined && typeof devSnake.boot_time === 'string') d['boot_time'] = devSnake.boot_time as string;
      if (d['timezone'] === undefined && typeof devSnake.timezone === 'string') d['timezone'] = devSnake.timezone as string;
      if (d['id'] === undefined && typeof devSnake.id === 'string') d['id'] = devSnake.id as string;
      if (d['locale'] === undefined && typeof devSnake.locale === 'string') d['locale'] = devSnake.locale as string;
      if (d['processor_count'] === undefined && typeof devSnake.processor_count === 'number') d['processor_count'] = devSnake.processor_count as number;
      if (d['processor_frequency'] === undefined && typeof devSnake.processor_frequency === 'number') d['processor_frequency'] = devSnake.processor_frequency as number;
      if (d['battery_temperature'] === undefined && typeof devSnake.battery_temperature === 'number') d['battery_temperature'] = devSnake.battery_temperature as number;
      if (d['chipset'] === undefined && typeof devSnake.chipset === 'string') d['chipset'] = devSnake.chipset as string;
      // defaults: family/model_id/simulator/battery_temperature
      if (d['family'] === undefined && typeof d['model'] === 'string') d['family'] = d['model'] as Object;
      if (d['model_id'] === undefined && typeof d['model'] === 'string') d['model_id'] = d['model'] as Object;
      if (d['simulator'] === undefined) d['simulator'] = false as Object;
      if (d['battery_temperature'] === undefined) d['battery_temperature'] = 28 as Object;
      ctxOut['device'] = d as Object;
    }
    // 应用上下文标准化
    interface AppCtxCamel { appName?: string; app_identifier?: string; appVersion?: string; appBuild?: string; app_version?: string; app_build?: string; app_name?: string; in_foreground?: boolean; is_split_apks?: boolean; packageName?: string; permissions?: Object; permissionsCsv?: string }
    const appRaw = srcCtx['app'] as AppCtxCamel;
    if (appRaw) {
      const a: Record<string, PrimitiveOut> = {};
      const appName = appRaw.app_name !== undefined ? appRaw.app_name : appRaw.appName;
      const appId = appRaw.app_identifier !== undefined ? appRaw.app_identifier : appRaw.packageName;
      const appVer = appRaw.app_version !== undefined ? appRaw.app_version : appRaw.appVersion;
      const appBuild = appRaw.app_build !== undefined ? appRaw.app_build : appRaw.appBuild;
      if (typeof appName === 'string') a['app_name'] = appName as string;
      if (typeof appId === 'string') a['app_identifier'] = appId as string;
      if (typeof appVer === 'string') a['app_version'] = appVer as string;
      if (typeof appBuild === 'string') a['app_build'] = appBuild as string;
      else if (typeof appBuild === 'number') a['app_build'] = String(appBuild);
      // 回退：若 app_name 缺失，使用 app_identifier 或 app_version 作为展示名
      if (a['app_name'] === undefined) {
        if (typeof appId === 'string') a['app_name'] = appId as string;
        else if (typeof appVer === 'string') a['app_name'] = appVer as string;
      }
      // 兼容 app_start_time / start_time（若上游注入了启动时间）
      try {
        const appAny = srcCtx['app'] as Record<string, PrimitiveOut>;
        const ast = appAny && typeof appAny['app_start_time'] === 'string' ? (appAny['app_start_time'] as string) : undefined;
        const st = appAny && typeof appAny['start_time'] === 'string' ? (appAny['start_time'] as string) : undefined;
        if (ast) (a as Record<string, PrimitiveOut>)['app_start_time'] = ast;
        if (st) (a as Record<string, PrimitiveOut>)['start_time'] = st;
      } catch (_) {}
      const fg = appRaw.in_foreground;
      if (typeof fg === 'boolean') a['in_foreground'] = fg as boolean;
      const split = appRaw.is_split_apks;
      if (typeof split === 'boolean') a['is_split_apks'] = split as boolean;
      // permissions 优先从 permissionsCsv 解析为对象映射（与 Android 接近：name -> granted）
      if (typeof appRaw.permissionsCsv === 'string' && appRaw.permissionsCsv.length > 0) {
        const arr = appRaw.permissionsCsv.split(',');
        const mapObj: Record<string, string> = {};
        for (let pi = 0; pi < arr.length; pi++) {
          const name = arr[pi];
          if (name && name.length > 0) mapObj[name] = 'granted';
        }
        (a as Record<string, Object>)['permissions'] = mapObj as Object;
      } else {
        const perms = appRaw.permissions;
        if (perms && typeof perms === 'object') (a as Record<string, Object>)['permissions'] = perms as Object;
      }
      ctxOut['app'] = a as Object;
    }
    // 操作系统上下文标准化
    interface OsCtxCamel { name?: string; version?: string; build?: string; kernelVersion?: string; rooted?: boolean; softwareModel?: string; buildFeatures?: string }
    const osRaw = srcCtx['os'] as OsCtxCamel;
    if (osRaw) {
      const o: Record<string, PrimitiveOut> = {};
      if (typeof osRaw.name === 'string') o['name'] = osRaw.name;
      if (typeof osRaw.version === 'string') o['version'] = osRaw.version;
      // build：若未提供，回退从 version/内核串中拆分（简化）
      if (osRaw.build && typeof osRaw.build === 'string') o['build'] = osRaw.build as string;
      if (typeof osRaw.kernelVersion === 'string') o['kernel_version'] = osRaw.kernelVersion;
      // 兼容 snake_case kernel_version（若上游即已是 snake）
      interface OsSnake { kernel_version?: string }
      const osSnakeRaw = srcCtx['os'];
      const osSnake = osSnakeRaw as OsSnake;
      if (o['kernel_version'] === undefined && osSnake && typeof osSnake.kernel_version === 'string') o['kernel_version'] = osSnake.kernel_version as string;
      if (o['build'] === undefined && typeof o['version'] === 'string') {
        const v = String(o['version']);
        const parts = v.split(' ');
        if (parts.length > 1) o['build'] = parts[parts.length - 1] as string;
      }
      // os.id：来源 versionId（若上游注入）
      try {
        const osAny2 = srcCtx['device'] as Record<string, PrimitiveOut>;
        const vid = osAny2 ? osAny2['versionId'] as string : undefined;
        if (vid && typeof vid === 'string') o['id'] = vid;
      } catch (_) {}
      if (typeof osRaw.rooted === 'boolean') o['rooted'] = osRaw.rooted;
      if (typeof osRaw.softwareModel === 'string') o['model_id'] = osRaw.softwareModel;
      if (typeof osRaw.buildFeatures === 'string') o['features'] = osRaw.buildFeatures;
      ctxOut['os'] = o as Object;
      try {
        // tags: os / os.name
        if (!out.tags) out.tags = {};
        if (typeof o['version'] === 'string' && typeof o['name'] === 'string') {
          out.tags['os'] = `${o['name']} ${o['version']}`;
        }
        if (typeof o['name'] === 'string') out.tags['os.name'] = String(o['name']);
      } catch (_) {}
    }
    // tags 派生：若 os.rooted 为 true/false，补充 tags['os.rooted']
    try {
      const osAny = ctxOut['os'] as Record<string, PrimitiveOut>;
      if (osAny && typeof osAny['rooted'] === 'boolean') {
        if (!out.tags) out.tags = {};
        out.tags['os.rooted'] = (osAny['rooted'] as boolean) ? 'yes' : 'no';
      }
    } catch (_) {}
    out.contexts = ctxOut as object;
    // tags: device（机型）与前台标记回退
    try {
      const devAny = ctxOut['device'] as Record<string, PrimitiveOut>;
      if (devAny && typeof devAny['model'] === 'string') {
        if (!out.tags) out.tags = {};
        out.tags['device'] = String(devAny['model']);
      }
      const appAny = ctxOut['app'] as Record<string, PrimitiveOut>;
      if (appAny && typeof appAny['in_foreground'] === 'boolean') {
        if (!out.tags) out.tags = {};
        if (!out.tags['is_foreground']) out.tags['is_foreground'] = (appAny['in_foreground'] as boolean) ? 'true' : 'false';
      }
    } catch (_) {}
    // 填充 release/environment/dist 默认值
    if (!out.release && this.options && typeof this.options.release === 'string') out.release = this.options.release;
    if (!out.environment && this.options && typeof this.options.environment === 'string') out.environment = this.options.environment;
    if (!out.dist) {
      const d = this.getDist();
      if (typeof d === 'string') out.dist = d;
    }
    // dist 进一步回退：使用 app_build（若存在，字符串或数字）
    try {
      if (!out.dist) {
        const appAny = ctxOut['app'] as Record<string, PrimitiveOut>;
        if (appAny) {
          const ab = appAny['app_build'] as PrimitiveOut;
          if (typeof ab === 'string') out.dist = ab;
          else if (typeof ab === 'number') out.dist = String(ab);
        }
      }
    } catch (_) {}
    out.breadcrumbs = this.mapBreadcrumbs(ev);
    // exception（从 exceptions -> exception.values）
    const exceptions: Array<SentryException> | undefined = evAsEvent.exceptions;
    if (exceptions && exceptions.length > 0) {
      const values: Array<ExceptionValueOut> = [];
      for (let i = 0; i < exceptions.length; i++) {
        const ex = exceptions[i];
        const mech: MechanismOut | undefined = ex.mechanism ? { type: ex.mechanism.type, handled: ex.mechanism.handled } : undefined;
        const val: ExceptionValueOut = { type: ex.type, value: ex.value, mechanism: mech };
        const exTidHolder: ExceptionWithThreadId = ex as ExceptionWithThreadId;
        if (typeof exTidHolder.threadId === 'number') val.thread_id = exTidHolder.threadId as number;
        // 映射异常栈
        if (ex.stacktrace && ex.stacktrace.frames && ex.stacktrace.frames.length > 0) {
          const st: StackTraceOut = { frames: [] };
          for (let j = 0; j < ex.stacktrace.frames.length; j++) {
            const f = ex.stacktrace.frames[j];
            const fo: StackFrameOut = {
              filename: f.filename,
              function: f.function,
              module: f.module,
              lineno: f.lineno,
              colno: f.colno,
              abs_path: f.abs_path,
              in_app: f.in_app,
              native: false,
            };
            st.frames.push(fo);
          }
          val.stacktrace = st;
        }
        values.push(val);
      }
      out.exception = { values: values };
    }
    // threads（从 threads -> threads.values），并包含每个线程的 stacktrace
    const threads: Array<SentryThread> | undefined = (ev as SentryEvent).threads;
    if (threads && threads.length > 0) {
      const tv: Array<ThreadOut> = [];
      for (let i = 0; i < threads.length; i++) {
        const t = threads[i];
        const to: ThreadOut = { id: t.id, name: t.name, priority: t.priority, state: t.state, crashed: t.crashed, current: t.current, daemon: t.daemon, main: t.main, data: t.data, snapshot: true };
        if (t.stacktrace && t.stacktrace.frames && t.stacktrace.frames.length > 0) {
          const stT: StackTraceOut = { frames: [] };
          for (let k = 0; k < t.stacktrace.frames.length; k++) {
            const f = t.stacktrace.frames[k];
            const fo: StackFrameOut = {
              filename: f.filename,
              function: f.function,
              module: f.module,
              lineno: f.lineno,
              colno: f.colno,
              abs_path: f.abs_path,
              in_app: f.in_app,
              native: false,
            };
            stT.frames.push(fo);
          }
          to.stacktrace = stT;
        }
        tv.push(to);
      }
      out.threads = { values: tv };
    }
    // extra（从 extras -> extra）
    if (ev.extras) out.extra = ev.extras;
    // sdk
    if ((ev as SentryEvent).sdk) {
      const s = (ev as SentryEvent).sdk as SdkVersion;
      const pkgs: Array<SdkPackageOut> = [];
      if (s.packages) {
        for (let i = 0; i < s.packages.length; i++) {
          const p = s.packages[i];
          pkgs.push({ name: p.name, version: p.version });
        }
      }
      const sdkOut: SdkOut = { name: s.name, version: s.version, packages: pkgs };
      out.sdk = sdkOut;
    }
    // sdk.integrations（可选）：从 options 推导或留空（Android 会填充）。此处先不输出，保持最小集。
    // measurements（仅 transaction 有），并补充 transaction 相关字段
    const tx = ev as SentryTransaction;
    if (tx && tx.measurements) {
      const keys = Object.keys(tx.measurements);
      if (keys.length > 0) {
        const rec: Record<string, MeasurementOut> = {};
        for (let i = 0; i < keys.length; i++) {
          const k = keys[i];
          const m = tx.measurements[k];
          rec[k] = { value: m.value, unit: m.unit };
        }
        out.measurements = rec;
      }
    }
    // transaction 特有字段：name、开始/结束时间与 trace contexts（已在创建时写入）
    if (tx && typeof tx.transaction === 'string') {
      // 将 name 作为 message 或 contexts.trace 自行呈现，Sentry UI 会读取 transaction.item
      // ArkTS 限制下，仅补充 tags 以辅助云端识别
      if (!out.tags) out.tags = {};
      out.tags['transaction'] = tx.transaction;
    }
    // user/release/environment/dist/fingerprint
    if ((ev as SentryEvent).user) {
      const u = (ev as SentryEvent).user as Record<string, string>;
      const outUser: Record<string, string> = {};
      const keys = Object.keys(u);
      for (let i = 0; i < keys.length; i++) {
        const k = keys[i];
        const v = u[k];
        if (typeof v === 'string') outUser[k] = v;
      }
      if (!outUser['ip_address']) outUser['ip_address'] = '{{auto}}';
      out.user = outUser as object;
    }
    // Event 级别的值优先，但仅在有效时才覆盖
    if (ev.release) out.release = ev.release;
    if (ev.environment) out.environment = ev.environment;
    if (ev.dist) out.dist = ev.dist;
    out.fingerprint = ev.fingerprint;
    // 若 release 为空，尝试从 app 上下文派生：packageName@version+build
    if (!out.release) {
      try {
        const appAny = (out.contexts as Record<string, Object>)['app'] as Record<string, PrimitiveOut>;
        const id = appAny ? (appAny['app_identifier'] as string) : undefined;
        const ver = appAny ? (appAny['app_version'] as string) : undefined;
        const build = appAny ? (appAny['app_build'] as string) : undefined;
        if (id && ver) out.release = build ? `${id}@${ver}+${build}` : `${id}@${ver}`;
      } catch (_) {}
    }
    return out;
  }

  private levelToString(level?: SentryLevel): string | undefined {
    if (level === undefined) return undefined;
    switch (level) {
      case SentryLevel.Debug: return 'debug';
      case SentryLevel.Info: return 'info';
      case SentryLevel.Warning: return 'warning';
      case SentryLevel.Error: return 'error';
      case SentryLevel.Fatal: return 'fatal';
      default: return undefined;
    }
  }

  private mapBreadcrumbs(ev: SentryBaseEvent): Array<BreadcrumbOut> {
    const out: Array<BreadcrumbOut> = [];
    if (!ev.breadcrumbs || ev.breadcrumbs.length === 0) return out;
    for (let i = 0; i < ev.breadcrumbs.length; i++) {
      const b: Breadcrumb = ev.breadcrumbs[i] as Breadcrumb;
      const rec: Record<string, string> = {};
      if (b.data) {
        const keys = Object.keys(b.data as Record<string, string>);
        for (let j = 0; j < keys.length; j++) {
          const k = keys[j];
          const v = (b.data as Record<string, string>)[k];
          rec[k] = v;
        }
      }
      const lvl = this.levelToString(b.level);
      // 规范化类别与 type：贴近 Android Demo
      let cat = b.category;
      let type = b.type;
      if (cat === 'action' || (cat && cat.indexOf('ui.click') >= 0)) {
        cat = 'ui.click';
        type = 'user';
      } else if (cat && cat.indexOf('device.screen') >= 0) {
        cat = 'device.screen';
        type = 'navigation';
      } else if (cat && cat.indexOf('network') >= 0) {
        cat = 'network.event';
        type = 'system';
      } else if (cat && cat.indexOf('device') >= 0) {
        cat = 'device.event';
        type = 'system';
      } else if (cat && cat.indexOf('lifecycle') >= 0) {
        if (cat.indexOf('ui') >= 0) cat = 'ui.lifecycle'; else if (cat.indexOf('app') >= 0) cat = 'app.lifecycle'; else cat = 'ui.lifecycle';
        type = 'navigation';
      } else if (cat === 'log') {
        type = 'debug';
      }
      const ob: BreadcrumbOut = { timestamp: b.timestamp, message: b.message, category: cat, level: lvl, type: type, data: rec };
      out.push(ob);
    }
    return out;
  }

  // 从 DSN 构建真正的上报地址
  private buildEndpointFromDsn(dsn: string): string {
    try {
      const m = dsn.match(/^https?:\/\/([^@]+)@([^\/]+)\/(\d+)(?:\/.*)?$/);
      if (m) {
        const publicKey = m[1];
        const host = m[2];
        const projectId = m[3];
        return `https://${host}/api/${projectId}/envelope/?sentry_key=${publicKey}&sentry_version=7`;
      }
    } catch (e) {
      console.error(`[Sentry] [HttpTransport] buildEndpointFromDsn err: ${e}`);
    }
    return dsn;
  }

  private isRateLimited(): boolean {
    if (this.rateLimitUntilMs === null) return false;
    return Date.now() < this.rateLimitUntilMs;
  }

  private applyRateLimitFromHeaders(result: HttpResponseWithHeaders): void {
    try {
      const headers: Record<string, string> | undefined = result.header;
      let now = Date.now();
      let retrySeconds: number | undefined = undefined;
      if (headers) {
        const xrl = headers['X-Sentry-Rate-Limits'] || headers['x-sentry-rate-limits'];
        if (typeof xrl === 'string' && xrl.length > 0) {
          const first = xrl.split(',')[0];
          const secStr = first.split(':')[0];
          const sec = parseInt(secStr, 10);
          if (!isNaN(sec) && sec > 0) retrySeconds = sec;
        }
        const ra = headers['Retry-After'] || headers['retry-after'];
        if (retrySeconds === undefined && typeof ra === 'string' && ra.length > 0) {
          const sec = parseInt(ra, 10);
          if (!isNaN(sec) && sec > 0) retrySeconds = sec;
          else {
            const ts = Date.parse(ra);
            if (!isNaN(ts)) retrySeconds = Math.max(0, Math.ceil((ts - now) / 1000));
          }
        }
      }
      if (retrySeconds !== undefined) {
        this.rateLimitUntilMs = now + retrySeconds * 1000;
        if (this.options.debug) console.warn(`[Sentry] [HttpTransport] rate limited for ${retrySeconds}s`);
      }
    } catch (e) {
      if (this.options.debug) console.warn('[Sentry] [HttpTransport] applyRateLimitFromHeaders failed');
    }
  }

  // 将宽泛 object 头部转换为 Record<string, string>
  private coerceHeaders(obj: object | undefined): Record<string, string> | undefined {
    if (!obj) return undefined;
    const out: Record<string, string> = {};
    const rec = obj as Record<string, string | number | boolean>;
    const keys = Object.keys(rec);
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      const v = rec[k];
      out[k] = typeof v === 'string' ? v : String(v);
    }
    return out;
  }

  public async flush(timeout: number = 15000): Promise<boolean> {
    // Prevent concurrent flush execution
    if (this.isFlushing) {
      // Already in progress, skip
      return true;
    }
    this.isFlushing = true;
    try {
      if (!this.cache) {
        if (this.options.debug) console.info('[Sentry] [HttpTransport] flush: no cache configured');
        this.isFlushing = false;
        return true;
      }
      const start = Date.now();
      
      // 1) Flush JSON events (native SDK events)
      const events = this.cache.all();
      // Flushing cached events
      
      let successCount = 0;
      let failCount = 0;
      for (let i = 0; i < events.length; i++) {
        const ev = events[i];
        if (Date.now() - start > timeout) {
          console.warn('[Sentry] [HttpTransport] flush: timeout reached during JSON events');
          break;
        }
        try {
          const sent = await this.send(ev);
          if (sent) {
            this.cache.discard(ev.event_id);
            successCount++;
          } else {
            failCount++;
          }
        } catch (err) {
          failCount++;
          const em = ((): string => {
            const maybe = err as ErrorMsgLike;
            return typeof maybe?.message === 'string' ? maybe.message : String(err);
          })();
          console.error(`[Sentry] HttpTransport flush send failed for event ${ev.event_id}: ${em}`);
        }
      }
      
      // 2) Flush raw envelopes (Dart/Flutter events)
      const rawEnvelopes = this.cache.allRawEnvelopes();
      
      let rawSuccessCount = 0;
      let rawFailCount = 0;
      for (let i = 0; i < rawEnvelopes.length; i++) {
        const env = rawEnvelopes[i];
        if (Date.now() - start > timeout) {
          console.warn('[Sentry] [HttpTransport] flush: timeout reached during raw envelopes');
          break;
        }
        try {
          // Send directly without caching again (to avoid infinite loop)
          const sent = await this.sendRawEnvelopeWithoutCache(env.bytes);
          if (sent) {
            this.cache.discardRawEnvelope(env.id);
            rawSuccessCount++;
          } else {
            rawFailCount++;
          }
        } catch (err) {
          rawFailCount++;
          const em = ((): string => {
            const maybe = err as ErrorMsgLike;
            return typeof maybe?.message === 'string' ? maybe.message : String(err);
          })();
          console.error(`[Sentry] HttpTransport flush send failed for raw envelope ${env.id}: ${em}`);
        }
      }
      
      // 3) 尝试发送 client_report
      try {
        await this.sendClientReport();
      } catch (err) {
        console.error(`[Sentry] HttpTransport failed to send client report: ${err}`);
      }

      // Flush completed

      // 4) Schedule retry if there are remaining envelopes
      const remaining = this.cache.pendingEnvelopeIds();
      if (remaining.length > 0) {
        // Scheduling retry for remaining envelopes
        setTimeout(() => {
          this.flush(timeout).catch((e: Error) => {
            console.error(`[Sentry] Retry flush failed: ${e}`);
          });
        }, 3000);
      }

      return true;
    } catch (err) {
      console.error(`[Sentry] HttpTransport FATAL ERROR in flush: ${err}`);
      return false;
    } finally {
      this.isFlushing = false; // Always release the lock
    }
  }
  
  /**
   * Send raw envelope without caching on failure (used during flush to avoid infinite loop).
   * Also injects 'sent_at' into envelope header if missing (required by Sentry server).
   */
  private async sendRawEnvelopeWithoutCache(envelopeBytes: Uint8Array): Promise<boolean> {
    try {
      if (this.isRateLimited()) {
        return false;
      }
      
      // Inject sent_at into envelope header if missing
      const processedBytes = this.injectSentAtIntoEnvelope(envelopeBytes);
      
      const url = this.endpoint;
      const result = await this.client.request(
        url,
        {
          method: http.RequestMethod.POST,
          header: {
            'Content-Type': 'application/x-sentry-envelope',
            'User-Agent': 'sentry.harmony.ets/0.1.0'
          },
          connectTimeout: 10000,
          extraData: processedBytes.buffer.slice(processedBytes.byteOffset, processedBytes.byteOffset + processedBytes.byteLength) as ArrayBuffer,
        });
      if (result.responseCode >= 200 && result.responseCode < 300) {
        return true;
      } else {
        if (result.responseCode === 429) {
          const headers = this.coerceHeaders((result as HttpResponsePossiblyHasHeader).header);
          this.applyRateLimitFromHeaders({ header: headers });
        }
        console.error(`[Sentry] HttpTransport cached envelope send failed: responseCode=${result.responseCode}`);
        return false;
      }
    } catch (err) {
      const em = ((): string => {
        const maybe = err as ErrorLike;
        const msg = typeof maybe?.message === 'string' ? maybe.message : String(err);
        const code = (maybe && (typeof maybe.code === 'string' || typeof maybe.code === 'number')) ? String(maybe.code) : '';
        return code ? `${msg} - ${code}` : msg;
      })();
      console.error(`[Sentry] HttpTransport cached envelope send exception: ${em}`);
      return false;
    }
  }

  /**
   * Injects 'sent_at' field into envelope header if missing.
   * Sentry server requires sent_at for proper event timestamp handling.
   * Format: {"event_id":"...","sdk":{...},...} -> {"sent_at":"...","event_id":"...","sdk":{...},...}
   */
  private injectSentAtIntoEnvelope(envelopeBytes: Uint8Array): Uint8Array {
    try {
      // Find the first newline (end of envelope header)
      let headerEndIdx = -1;
      for (let i = 0; i < Math.min(envelopeBytes.length, 2000); i++) {
        if (envelopeBytes[i] === 0x0A) { // '\n'
          headerEndIdx = i;
          break;
        }
      }
      
      if (headerEndIdx === -1) {
        console.warn('[Sentry] [HttpTransport] Could not find envelope header end, sending as-is');
        return envelopeBytes;
      }
      
      // Extract and parse header
      const headerBytes = envelopeBytes.slice(0, headerEndIdx);
      const decoder = new util.TextDecoder('utf-8');
      const headerStr = decoder.decodeToString(headerBytes);
      
      // Check if sent_at already exists
      if (headerStr.includes('"sent_at"')) {
        // Already has sent_at, no modification needed
        return envelopeBytes;
      }
      
      // Parse header JSON and add sent_at
      let headerObj: Record<string, Object>;
      try {
        headerObj = JSON.parse(headerStr) as Record<string, Object>;
      } catch (e) {
        console.warn(`[Sentry] [HttpTransport] Failed to parse envelope header: ${e}`);
        return envelopeBytes;
      }
      
      // Add sent_at at the beginning (Sentry convention)
      const sentAt = new Date().toISOString();
      // ArkTS doesn't support object spread, manually copy properties
      headerObj['sent_at'] = sentAt;
      const newHeaderStr = JSON.stringify(headerObj);
      
      // Rebuild envelope with new header
      const encoder = new util.TextEncoder();
      const newHeaderBytes = encoder.encodeInto(newHeaderStr);
      const restBytes = envelopeBytes.slice(headerEndIdx); // includes the newline and rest
      
      // Combine new header with rest of envelope
      const newEnvelope = new Uint8Array(newHeaderBytes.length + restBytes.length);
      newEnvelope.set(newHeaderBytes, 0);
      newEnvelope.set(restBytes, newHeaderBytes.length);
      
      return newEnvelope;
    } catch (err) {
      console.error(`[Sentry] [HttpTransport] Error injecting sent_at: ${err}`);
      return envelopeBytes; // Return original on error
    }
  }

  close(): void {
    if (this.options.debug) console.info('[Sentry] [HttpTransport] close called');
  }


}
