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

import http from '@ohos.net.http';
import fileio from '@ohos.fileio';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { SentryOhos } from '../core/SentryOhos';
import { ReplayPayload, ReplayPayloadEvent, ReplayPayloadEventData, RRWebBreadcrumbEventOut, RRWebSpanEventOut } from './types';
import type { BreadcrumbPayload } from './rrweb/RRWebBreadcrumbEvent';
import type { SpanPayload } from './rrweb/RRWebSpanEvent';
import { replayInfo, replayWarn } from './ReplayLogger';

interface SdkInfo { name: string; version: string }
interface EnvelopeHeader { sent_at: string; event_id?: string; dsn?: string; sdk?: SdkInfo }
interface ItemHeaderReplay { type: 'replay_event'; length?: number; content_type?: string }
interface ItemHeaderRecording { type: 'replay_recording'; length?: number; content_type?: string }
interface ItemHeaderReplayVideo { type: 'replay_video'; length?: number; content_type?: string; filename?: string }

interface HasTimestamp { timestamp?: number }

const RR_TYPE_META: number = 4;
const RR_TYPE_CUSTOM: number = 5;

interface RRWebMetaPayload { href: string; height: number; width: number }
interface RRWebMetaJson { type: number; timestamp: number; data: RRWebMetaPayload }
interface RRWebVideoPayload {
  segmentId: number;
  durationMs: number;
  duration: number;
  frameCount: number;
  frameRateType: 'constant';
  frameRate: number;
  height: number;
  width: number;
  left: number;
  top: number;
  size: number;
  encoding: 'h264';
  container: 'mp4';
  url?: string;
}
interface RRWebCustomData<T> { tag: string; payload: T }
interface RRWebCustomJson<T> { type: number; timestamp: number; data: RRWebCustomData<T> }
type RRWebEventJson = RRWebMetaJson | RRWebCustomJson<RRWebVideoPayload> | RRWebCustomJson<Object>

// 占位 activity 的 payload 类型，避免使用匿名对象类型声明
interface ActivityPayload { note: string }

class BreadcrumbPayloadRecord {
  public category: string;
  public level?: string;
  public message?: string;
  public data?: Record<string, string>;

  constructor(payload?: BreadcrumbPayload) {
    this.category = payload && payload.category ? payload.category : 'default';
    if (payload?.level) {
      this.level = payload.level;
    }
    if (payload?.message) {
      this.message = payload.message;
    }
    if (payload?.data) {
      this.data = payload.data;
    }
  }
}

class SpanPayloadRecord {
  public operation: string;
  public description?: string;
  public durationMs?: number;
  public traceId?: string;
  public spanId?: string;

  constructor(payload?: SpanPayload) {
    this.operation = payload && payload.operation ? payload.operation : 'default';
    if (payload?.description) {
      this.description = payload.description;
    }
    if (payload?.durationMs && typeof payload.durationMs === 'number') {
      this.durationMs = payload.durationMs;
    }
    if (payload?.traceId) {
      this.traceId = payload.traceId;
    }
    if (payload?.spanId) {
      this.spanId = payload.spanId;
    }
  }
}

class OptionsPayloadRecord {
  public constructor() {}
}

class ActivityPayloadRecord {
  public note: string;

  constructor(note: string) {
    this.note = note;
  }
}

interface TimestampCarrier {
  timestamp?: number;
}

class GesturePayloadTimestampExtractor {
  public static getTimestamp(source: Object | undefined): number | undefined {
    if (!source) {
      return undefined;
    }
    const carrier = source as TimestampCarrier;
    const value = carrier.timestamp;
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value;
    }
    return undefined;
  }
}

interface ReplayRecording { segment_id: number; payload: Array<RRWebEventJson> }
interface ReplayEventEnvelope {
  type: 'replay_event'; event_id: string; replay_id?: string; segment_id?: number;
  timestamp?: number; replay_start_timestamp?: number; urls?: Array<string>;
  replay_type?: string; platform?: string; error_ids?: Array<string>; trace_ids?: Array<string>;
  release?: string; environment?: string;
  started_at?: string; finished_at?: string;
  duration?: number; duration_ms?: number;
}

interface MsgpackEntry { key: string; value: Uint8Array }
interface ErrorMessageCarrier { message?: string }
interface Mp4Metrics { durationMs?: number; frameCount?: number }

export class ReplayEnvelopeSender {
  // 简单速率控制与退避（进程级）
  private static nextSendAfterMs: number = 0;
  private static backoffMs: number = 0;
  private static readonly baseBackoffMs: number = 2000;
  private static readonly maxBackoffMs: number = 30000;
  private static readonly minPaceMs: number = 1000;

  private jitter(ms: number): number {
    const j = Math.floor(ms * 0.2);
    const r = Math.floor(Math.random() * (j + 1));
    return ms + r;
  }

  private async sleep(ms: number): Promise<void> {
    return await new Promise<void>((resolve) => { setTimeout(() => resolve(), ms); });
  }
  async send(serverUrl: string, payload: ReplayPayload): Promise<boolean> {
    const url = this.buildEndpointFromDsn(serverUrl);
    
    const ok = await this.sendBinary(url, payload);
    if (ok) {
      return true;
    }
    const envelope = this.buildStandardEnvelope(payload);
    const client = http.createHttp();
    const headers: Record<string, string> = {
      'Content-Type': 'application/x-sentry-envelope',
      'User-Agent': 'sentry.harmony.replay/0.1.0'
    };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: envelope.buffer,
      connectTimeout: 10000,
      readTimeout: 30000, // Increased timeout for large video files
    };
    try {
      const res: http.HttpResponse = await client.request(url, options);
      client.destroy();
      const success = (res.responseCode as number) >= 200 && (res.responseCode as number) < 300;
      return success;
    } catch (err) {
      try { client.destroy(); } catch (_) {}
      return false;
    }
  }

  async sendBinary(serverUrl: string, payload: ReplayPayload): Promise<boolean> {
    try {
      // 分段节流：若上次发送后冷却期未过，则等待
      try {
        const now = Date.now();
        if (ReplayEnvelopeSender.nextSendAfterMs > now) {
        const delay = ReplayEnvelopeSender.nextSendAfterMs - now;
        await this.sleep(delay);
        }
      } catch (_) {}

      const parts: Array<Uint8Array> = [];
      const pushLine = (text: string): void => { parts.push(this.encodeUtf8(text + '\n')); };
      const pushBytes = (bytes: Uint8Array): void => { parts.push(bytes); parts.push(this.encodeUtf8('\n')); };

      const sdk: SdkInfo = { name: 'sentry.javascript.harmony', version: '0.1.0' };
      // 仅归一化一次，避免生成不同的 replay_id
      const normalized = this.normalizeReplayPayload(payload);
      const recordingEvents = this.buildMinimalRecordingEvents(normalized);
      // buildMinimalRecordingEvents 会更新 normalized.timestamp 和 normalized.replay_start_timestamp
      // 必须在 buildMinimalRecordingEvents 之后读取这些值
      const headerEventId = (normalized.replay_id && normalized.replay_id.length > 0) ? normalized.replay_id : this.generateUuidV4();
      (normalized as ReplayPayload).replay_id = headerEventId;
      const headerObj: EnvelopeHeader = { sent_at: new Date().toISOString(), event_id: headerEventId, sdk: sdk } as EnvelopeHeader;
      pushLine(JSON.stringify(headerObj));

      const replayEventObj: ReplayEventEnvelope = {
        type: 'replay_event',
        event_id: headerEventId,
        replay_id: normalized.replay_id,
        segment_id: normalized.segment_id,
        timestamp: (normalized.timestamp ?? Math.floor(Date.now() / 1000)),
        replay_start_timestamp: (normalized.replay_start_timestamp ?? Math.floor(Date.now() / 1000)),
        urls: normalized.urls,
        replay_type: normalized.replay_type,
        platform: 'android',
      };
      // 若存在近期错误事件 id，将其加入 error_ids 以便 Web 关联（优先使用真实 error_id）
      try {
        const lastErr = SentryOhos.getLastErrorEventId();
        if (typeof lastErr === 'string' && lastErr.length > 0) {
          (replayEventObj as ReplayEventEnvelope).error_ids = [ lastErr ];
        }
      } catch (_) {}
      // 透传 release/environment（如存在）
      try {
        const rel = (payload as ReplayPayload).release;
        if (typeof rel === 'string' && rel.length > 0) replayEventObj.release = rel;
      } catch (_) {}
      try {
        const env = (payload as ReplayPayload).environment;
        if (typeof env === 'string' && env.length > 0) replayEventObj.environment = env;
      } catch (_) {}
      // 只有当上面未填充真实 error_id 时，才降级使用 payload 中的占位 error_ids
      if (!(replayEventObj as ReplayEventEnvelope).error_ids || ((replayEventObj as ReplayEventEnvelope).error_ids as Array<string>).length === 0) {
        if (normalized.error_ids && normalized.error_ids.length > 0) {
          (replayEventObj as ReplayEventEnvelope).error_ids = normalized.error_ids;
        }
      }
      if (normalized.trace_ids) replayEventObj.trace_ids = normalized.trace_ids;
      const replayEventJson = JSON.stringify(replayEventObj);
      const recordingJson = JSON.stringify(recordingEvents);
      // 根据 Android SDK 实现，移动端 replay envelope 格式为：
      // 单个 replay_video 类型的 item，payload 为 MessagePack 编码的 map：
      // { "replay_event": <JSON bytes>, "replay_recording": <JSON bytes>, "replay_video": <video bytes> }
      // replay_recording 格式: {"segment_id": N}\n[RRWeb events array]

      const videoBytes = this.readVideoBytes(payload.videoPath);

      if (videoBytes && videoBytes.length > 0) {
        // 构建 replay_event JSON bytes
        const replayEventBytes = this.encodeUtf8(replayEventJson);
        
        // 构建 replay_recording: {"segment_id": N}\n[RRWeb events array]
        const segmentMeta = JSON.stringify({ segment_id: normalized.segment_id ?? 0 });
        const recordingPayload = segmentMeta + '\n' + recordingJson;
        const recordingBytes = this.encodeUtf8(recordingPayload);
        
        // 使用 MessagePack 编码 map: { replay_event, replay_recording, replay_video }
        const msgpackPayload = this.serializeToMsgpack({
          'replay_event': replayEventBytes,
          'replay_recording': recordingBytes,
          'replay_video': videoBytes
        });
        
        // 发送单个 replay_video 类型的 item
        const itemHeader = JSON.stringify({ type: 'replay_video', length: msgpackPayload.length });
        pushLine(itemHeader);
        pushBytes(msgpackPayload);
      }

      const body = this.concat(parts);
      const client = http.createHttp();
      const headers: Record<string, string> = {
        'Content-Type': 'application/x-sentry-envelope',
        'User-Agent': 'sentry.harmony.replay/0.1.0'
      };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: body.buffer,
        connectTimeout: 10000,
        readTimeout: 15000,
      };
      const endpoint = this.buildEndpointFromDsn(serverUrl);
      const res: http.HttpResponse = await client.request(endpoint, options);
      client.destroy();
      const code = res.responseCode as number;
      if (code >= 200 && code < 300) {
        // 成功：重置退避，设置最小发送间隔
        ReplayEnvelopeSender.backoffMs = 0;
        ReplayEnvelopeSender.nextSendAfterMs = Date.now() + ReplayEnvelopeSender.minPaceMs;
        return true;
      }
      if (code === 429) {
        // 429：指数退避 + 抖动
        const base = ReplayEnvelopeSender.backoffMs > 0 ? Math.min(ReplayEnvelopeSender.backoffMs * 2, ReplayEnvelopeSender.maxBackoffMs) : ReplayEnvelopeSender.baseBackoffMs;
        ReplayEnvelopeSender.backoffMs = base;
        const waitMs = this.jitter(base);
        ReplayEnvelopeSender.nextSendAfterMs = Date.now() + waitMs;
        return false;
      }
      // 其它错误：轻微退避
      const back = ReplayEnvelopeSender.backoffMs > 0 ? Math.min(ReplayEnvelopeSender.backoffMs * 2, ReplayEnvelopeSender.maxBackoffMs) : Math.floor(ReplayEnvelopeSender.baseBackoffMs / 2);
      ReplayEnvelopeSender.backoffMs = back;
      ReplayEnvelopeSender.nextSendAfterMs = Date.now() + this.jitter(back);
      return false;
    } catch (err) {
      return false;
    }
  }

  private encodeUtf8(text: string): Uint8Array {
    const codePoints: number[] = [];
    for (let i = 0; i < text.length; i++) {
      let code = text.charCodeAt(i);
      if (code < 0x80) codePoints.push(code); else if (code < 0x800) {
        codePoints.push(0xc0 | (code >> 6)); codePoints.push(0x80 | (code & 0x3f));
      } else if ((code & 0xfc00) === 0xd800 && i + 1 < text.length && (text.charCodeAt(i + 1) & 0xfc00) === 0xdc00) {
        const high = code; const low = text.charCodeAt(++i);
        const cp = ((high & 0x3ff) << 10) + (low & 0x3ff) + 0x10000;
        codePoints.push(0xf0 | (cp >> 18)); codePoints.push(0x80 | ((cp >> 12) & 0x3f));
        codePoints.push(0x80 | ((cp >> 6) & 0x3f)); codePoints.push(0x80 | (cp & 0x3f));
      } else {
        codePoints.push(0xe0 | (code >> 12)); codePoints.push(0x80 | ((code >> 6) & 0x3f)); codePoints.push(0x80 | (code & 0x3f));
      }
    }
    return new Uint8Array(codePoints);
  }

  private concat(chunks: Array<Uint8Array>): Uint8Array {
    let total = 0; for (let i = 0; i < chunks.length; i++) total += chunks[i].length;
    const out = new Uint8Array(total); let offset = 0;
    for (let i = 0; i < chunks.length; i++) { out.set(chunks[i], offset); offset += chunks[i].length; }
    return out;
  }

  /**
   * Serialize a map of string keys to byte arrays using MessagePack format.
   * Format matches Android SDK: map header + (string key + binary value) pairs
   */
  private serializeToMsgpack(map: Record<string, Uint8Array>): Uint8Array {
    const chunks: Array<Uint8Array> = [];
    const keys = Object.keys(map);
    
    // Write map header: 0x80 | map.size (fixmap for up to 15 elements)
    chunks.push(new Uint8Array([0x80 | keys.length]));
    
    for (const key of keys) {
      const keyBytes = this.encodeUtf8(key);
      const valueBytes = map[key];
      
      // Pack the key as a string (str 8 format: 0xd9 + 1-byte length + string bytes)
      chunks.push(new Uint8Array([0xd9, keyBytes.length]));
      chunks.push(keyBytes);
      
      // Pack the value as binary (bin 32 format: 0xc6 + 4-byte big-endian length + bytes)
      const lenBytes = new Uint8Array(4);
      const len = valueBytes.length;
      lenBytes[0] = (len >>> 24) & 0xff;
      lenBytes[1] = (len >>> 16) & 0xff;
      lenBytes[2] = (len >>> 8) & 0xff;
      lenBytes[3] = len & 0xff;
      chunks.push(new Uint8Array([0xc6]));
      chunks.push(lenBytes);
      chunks.push(valueBytes);
    }
    
    return this.concat(chunks);
  }

  private normalizeReplayId(id: string): string {
    if (!id || id.length === 0) {
      return '';
    }
    const hex: Array<string> = [];
    let acc = 0;
    for (let i = 0; i < id.length; i++) {
      acc = (acc * 131 + (id.charCodeAt(i) & 0xffff)) >>> 0;
      const h = (acc & 0xff).toString(16);
      hex.push(h.length === 1 ? ('0' + h) : h);
      if (hex.length >= 32) {
        break;
      }
    }
    while (hex.length < 32) {
      hex.push('00');
    }
    return hex.join('').slice(0, 32).toLowerCase();
  }

  // 安全地解码 UTF-8（限制最大长度，避免编译器 TextDecoder 依赖）
  private safeDecodeUtf8(bytes: Uint8Array, maxLen: number): string {
    const limit = Math.min(bytes.length, Math.max(0, maxLen));
    let out = '';
    for (let i = 0; i < limit; i++) {
      out += String.fromCharCode(bytes[i]);
    }
    return out;
  }

  private buildStandardEnvelope(payload: ReplayPayload): Uint8Array {
    const parts: Array<Uint8Array> = [];
    const pushLine = (text: string): void => { parts.push(this.encodeUtf8(text + '\n')); };
    const pushBytes = (bytes: Uint8Array): void => { parts.push(bytes); parts.push(this.encodeUtf8('\n')); };

    const sdk: SdkInfo = { name: 'sentry.javascript.harmony', version: '0.1.0' };
    const normalized = this.normalizeReplayPayload(payload);
    const eventId: string = (normalized.replay_id && normalized.replay_id.length > 0) ? normalized.replay_id : this.generateUuidV4();
    (normalized as ReplayPayload).replay_id = eventId;
    const header: EnvelopeHeader = { sent_at: new Date().toISOString(), event_id: eventId, sdk: sdk };
    pushLine(JSON.stringify(header));

    const recordingEvents = this.buildMinimalRecordingEvents(normalized);
    const replayEventObj: ReplayEventEnvelope = {
      type: 'replay_event',
      event_id: eventId,
      replay_id: normalized.replay_id,
      segment_id: normalized.segment_id,
      timestamp: (normalized.timestamp ?? Math.floor(Date.now() / 1000)),
      replay_start_timestamp: (normalized.replay_start_timestamp ?? Math.floor(Date.now() / 1000)),
      urls: normalized.urls,
      replay_type: normalized.replay_type,
      platform: (normalized.platform && normalized.platform.length > 0) ? normalized.platform : 'android',
    };
    if (normalized.error_ids && normalized.error_ids.length > 0) {
      replayEventObj.error_ids = normalized.error_ids;
    }
    if (normalized.trace_ids && normalized.trace_ids.length > 0) {
      replayEventObj.trace_ids = normalized.trace_ids;
    }
    if (normalized.release && normalized.release.length > 0) {
      replayEventObj.release = normalized.release;
    }
    if (normalized.environment && normalized.environment.length > 0) {
      replayEventObj.environment = normalized.environment;
    }
    if (normalized.started_at) {
      replayEventObj.started_at = normalized.started_at;
    }
    if (normalized.finished_at) {
      replayEventObj.finished_at = normalized.finished_at;
    }
    if (typeof normalized.duration === 'number' && normalized.duration > 0) {
      replayEventObj.duration = normalized.duration;
    } else if (typeof replayEventObj.replay_start_timestamp === 'number' && typeof replayEventObj.timestamp === 'number') {
      const derivedSec = Math.max(1, replayEventObj.timestamp - replayEventObj.replay_start_timestamp);
      replayEventObj.duration = derivedSec;
    }
    if (typeof normalized.durationMs === 'number' && normalized.durationMs > 0) {
      replayEventObj.duration_ms = normalized.durationMs;
    } else if (typeof replayEventObj.duration === 'number') {
      replayEventObj.duration_ms = replayEventObj.duration * 1000;
    }
    const replayJsonStr = JSON.stringify(replayEventObj);
    const recordingJsonStr = JSON.stringify(recordingEvents);
    const recObj = { segment_id: normalized.segment_id ?? 0, payload: recordingEvents } as ReplayRecording;
    const recStr = JSON.stringify(recObj);

    const videoBytes = this.readVideoBytes(payload.videoPath);

    const replayHeader: ItemHeaderReplay = { type: 'replay_event', length: replayJsonStr.length, content_type: 'application/json' };
    pushLine(JSON.stringify(replayHeader));
    pushLine(replayJsonStr);

    const recHeader: ItemHeaderRecording = { type: 'replay_recording', length: recStr.length, content_type: 'application/json' };
    pushLine(JSON.stringify(recHeader));
    pushLine(recStr);

    if (videoBytes && videoBytes.length > 0) {
      const videoHeader: ItemHeaderReplayVideo = { type: 'replay_video', length: videoBytes.length, content_type: 'video/mp4', filename: 'replay.mp4' };
      pushLine(JSON.stringify(videoHeader));
      pushBytes(videoBytes);
    }

    return this.concat(parts);
  }

  private buildMinimalRecordingEvents(payload: ReplayPayload): Array<RRWebEventJson> {
    const startMs = (payload.replay_start_timestamp ?? Math.floor(Date.now() / 1000)) * 1000;
    const endMs = (payload.timestamp ?? Math.floor(Date.now() / 1000)) * 1000;
    let durationMs = Math.max(0, endMs - startMs);
    const frameRateRaw = (typeof payload.videoFrameRate === 'number' && payload.videoFrameRate > 0) ? payload.videoFrameRate : 2;
    const frameRate = Math.max(1, Math.floor(frameRateRaw));
    const widthRaw = (typeof payload.videoWidth === 'number' && payload.videoWidth > 0) ? payload.videoWidth : undefined;
    const heightRaw = (typeof payload.videoHeight === 'number' && payload.videoHeight > 0) ? payload.videoHeight : undefined;
    const width = widthRaw ? Math.floor(widthRaw) : 1920;
    const height = heightRaw ? Math.floor(heightRaw) : 1080;
    let frameCount = Math.max(1, Math.floor((durationMs / 1000) * frameRate));
    const events: Array<RRWebEventJson> = [];
    const href = (payload.urls && payload.urls.length > 0) ? payload.urls[0] : '/';
    // Android 顺序：video -> options(仅首段) -> meta
    const fileSize = this.safeFileSize(payload.videoPath);
    if (fileSize > 0 && (!payload.videoSizeBytes || payload.videoSizeBytes <= 0)) {
      (payload as ReplayPayload).videoSizeBytes = fileSize;
    }
    let hasValidVideo = false;
    if (payload.videoPath && payload.videoPath.length > 0 && fileSize > 0) {
      hasValidVideo = this.hasValidMp4(payload.videoPath, payload.videoSizeBytes);
      if (!hasValidVideo) {
        hasValidVideo = true;
      }
    }
    if (hasValidVideo) {
      const metrics = this.extractMp4Metrics(payload.videoPath, frameRate);
      if (metrics.durationMs && metrics.durationMs > 0) {
        durationMs = metrics.durationMs;
        frameCount = Math.max(1, Math.floor((durationMs / 1000) * frameRate));
      }
      if (metrics.frameCount && metrics.frameCount > 0) {
        frameCount = metrics.frameCount;
      }
    } else {
      frameCount = Math.max(1, Math.floor((durationMs / 1000) * frameRate));
    }
    if (hasValidVideo) {
      const effectiveSize = payload.videoSizeBytes && payload.videoSizeBytes > 0
        ? Math.floor(payload.videoSizeBytes)
        : fileSize;
      const videoPayload: RRWebVideoPayload = {
        segmentId: payload.segment_id ?? 0,
        durationMs,
        duration: durationMs,  // duration in milliseconds per Sentry mobile replay spec
        frameCount,
        frameRateType: 'constant',
        frameRate,
        height,
        width,
        left: 0,
        top: 0,
        size: effectiveSize,
        encoding: 'h264',
        container: 'mp4',
        url: 'attachment://replay.mp4'
      };
      const video: RRWebCustomJson<RRWebVideoPayload> = { type: RR_TYPE_CUSTOM, timestamp: startMs, data: { tag: 'video', payload: videoPayload } };
      events.push(video);
    }
    if ((payload.segment_id ?? 0) === 0) {
      const optionsPayload = new OptionsPayloadRecord();
      const options: RRWebCustomJson<Object> = { type: RR_TYPE_CUSTOM, timestamp: startMs, data: { tag: 'options', payload: optionsPayload } };
      events.push(options);
    }
    const startSec = Math.floor(startMs / 1000);
    const durationSec = Math.max(1, Math.ceil(durationMs / 1000));
    const endSec = startSec + durationSec;
    payload.replay_start_timestamp = startSec;
    payload.timestamp = endSec;
    payload.duration = durationSec;
    payload.durationMs = durationMs;
    try {
      payload.started_at = new Date(startSec * 1000).toISOString();
      payload.finished_at = new Date(endSec * 1000).toISOString();
    } catch (_) {}
    const metaData: RRWebMetaPayload = { href: href, height: height, width: width };
    const meta: RRWebMetaJson = { type: RR_TYPE_META, timestamp: startMs, data: metaData };
    events.push(meta);
    // 将 payload.events 的手势/输入/面包屑/span 转为 rrweb custom 事件
    try {
      for (let i = 0; i < payload.events.length; i++) {
        const ev = payload.events[i];
        if (!ev || !ev.type) continue;
        const tag = ev.type; // gesture/input/breadcrumb/span/snapshot(忽略)
        if (tag === 'snapshot') continue;
        // 统一映射
        if (tag === 'breadcrumb' || tag === 'span') {
          const list = ev.data as Array<RRWebBreadcrumbEventOut | RRWebSpanEventOut>;
          if (Array.isArray(list)) {
            for (let j = 0; j < list.length; j++) {
              const it = list[j];
              if (!it || typeof it !== 'object') {
                continue;
              }
              const ts = (typeof (it.timestampMs as number) === 'number') ? (it.timestampMs as number) : startMs;
              let payloadObj: Object;
              if (tag === 'breadcrumb') {
                payloadObj = new BreadcrumbPayloadRecord((it as RRWebBreadcrumbEventOut).payload);
              } else {
                payloadObj = new SpanPayloadRecord((it as RRWebSpanEventOut).payload);
              }
              const rr: RRWebCustomJson<Object> = {
                type: RR_TYPE_CUSTOM,
                timestamp: ts,
                data: { tag: tag, payload: payloadObj }
              };
              events.push(rr);
            }
          }
        } else {
          // 其它 gesture/input：按通用对象数组处理
          const list = ev.data as Array<Object>;
          if (Array.isArray(list)) {
            for (let j = 0; j < list.length; j++) {
              const item = list[j];
              if (!item || typeof item !== 'object') continue;
              const tsFromItem: number | undefined = GesturePayloadTimestampExtractor.getTimestamp(item as Object);
              const ts = (typeof tsFromItem === 'number') ? tsFromItem : startMs;
              const rr: RRWebCustomJson<Object> = {
                type: RR_TYPE_CUSTOM,
                timestamp: ts,
                data: { tag: tag, payload: item as Object }
              };
              events.push(rr);
            }
          }
        }
      }
    } catch (_) {}
    try {
      let cntGesture = 0, cntInput = 0, cntBreadcrumb = 0, cntSpan = 0, cntCustom = 0;
      for (let i = 0; i < events.length; i++) {
        const e = events[i] as RRWebCustomJson<Object>;
        const tag = e && e.data ? (e.data.tag as string) : '';
        if (tag === 'gesture') cntGesture++;
        else if (tag === 'input') cntInput++;
        else if (tag === 'breadcrumb') cntBreadcrumb++;
        else if (tag === 'span') cntSpan++;
        if (tag && tag.length > 0) cntCustom++;
      }
    } catch (_) {}
    // 若只有 options/meta，没有任何 custom 事件，增加占位 activity 事件，确保时间线可渲染
    try {
      let hasCustom = false;
      for (let i = 0; i < events.length; i++) {
        const e: RRWebCustomJson<Object> = events[i] as RRWebCustomJson<Object>;
        const d: RRWebCustomData<Object> | null = (e && e.data) ? (e.data as RRWebCustomData<Object>) : null;
        const tagVal: string | undefined = d ? (d.tag as string) : undefined;
        if (typeof tagVal === 'string' && tagVal.length > 0) { hasCustom = true; break; }
      }
      if (!hasCustom) {
        const payloadObj: ActivityPayload = { note: 'placeholder' };
        const placeholderPayload: Object = this.toActivityObject(payloadObj);
        const placeholderData: RRWebCustomData<Object> = { tag: 'activity', payload: placeholderPayload };
        const placeholder: RRWebCustomJson<Object> = { type: RR_TYPE_CUSTOM, timestamp: startMs, data: placeholderData };
        events.push(placeholder);
      }
    } catch (_) {}
    return events;
  }

  private extractMp4Metrics(path?: string, fallbackFrameRate?: number): Mp4Metrics {
    const result: Mp4Metrics = {};
    let file: fs.File | undefined;
    try {
      if (!path || path.length === 0) {
        return result;
      }
      let size = 0;
      try {
        const statFs = fs.statSync(path);
        size = statFs && typeof statFs.size === 'number' ? (statFs.size as number) : 0;
      } catch (_) {
        try {
          const st = fileio.statSync(path);
          size = st && typeof st.size === 'number' ? (st.size as number) : 0;
        } catch (_) {
          size = 0;
        }
      }
      if (!size || size <= 0) {
        return result;
      }
      const maxRead = Math.min(size, 1024 * 1024);
      const buffer = new ArrayBuffer(maxRead);
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const read = fs.readSync(file.fd, buffer);
      const len = (typeof read === 'number' && read > 0) ? Math.min(read, maxRead) : 0;
      
      let foundMvhd = false;

      // Helper to parse mvhd from buffer
      const parseMvhd = (buf: Uint8Array): boolean => {
        const idx = this.indexOfFourcc(buf, 'mvhd');
        if (idx < 0) { return false; }
        const ver = buf[idx + 4];
        if (ver === 0 && idx + 24 <= buf.length) {
          const ts = this.readUint32BE(buf, idx + 16);
          const dur = this.readUint32BE(buf, idx + 20);
          if (ts > 0 && dur > 0) {
            const ms = Math.floor((dur * 1000) / ts);
            if (ms > 0) { result.durationMs = ms; return true; }
          }
        } else if (ver === 1 && idx + 32 <= buf.length) {
          const ts = this.readUint32BE(buf, idx + 20);
          const dur = this.readUint64BE(buf, idx + 24);
          if (ts > 0 && dur > 0) {
             const ms = Math.floor((dur * 1000) / ts);
             if (ms > 0) { result.durationMs = ms; return true; }
          }
        }
        return false;
      };

      if (len > 0) {
        const bytes = new Uint8Array(buffer, 0, len);
        foundMvhd = parseMvhd(bytes);
      }

      // If not found in head, try tail (for files where moov is at the end)
      if (!foundMvhd && size > maxRead) {
        try {
          const tailSize = Math.min(size, 1024 * 1024); // 1MB tail
          const tailBuffer = new ArrayBuffer(tailSize);
          const offset = Math.max(0, size - tailSize);
          // fs.readSync with offset to read from tail
          const tailRead = fs.readSync(file.fd, tailBuffer, { offset: offset });
          if (tailRead > 0) {
            const tailBytes = new Uint8Array(tailBuffer, 0, tailRead);
            foundMvhd = parseMvhd(tailBytes);
            if (foundMvhd) {
            }
          }
        } catch (tailErr) {
           // ignore tail read errors
        }
      }
      if (result.durationMs && result.durationMs > 0 && fallbackFrameRate && fallbackFrameRate > 0) {
        result.frameCount = Math.max(1, Math.floor((result.durationMs / 1000) * fallbackFrameRate));
      }
    } catch (err) {
      // ignore metrics parse errors
    } finally {
      if (file) {
        try { fs.closeSync(file); } catch (_) {}
      }
    }
    return result;
  }

  // 判定 MP4 是否有效：大小阈值 + 头部包含 ftyp + 尝试扫描 moov（流式，容错）
  private hasValidMp4(path?: string, reportedSize?: number): boolean {
    let file: fs.File | undefined;
    try {
      if (!path || path.length === 0) {
        return false;
      }
      let size = 0;
      try {
        const statFs = fs.statSync(path);
        size = statFs && typeof statFs.size === 'number' ? (statFs.size as number) : 0;
      } catch (_) {
        try {
          const st = fileio.statSync(path);
          size = (st.size as number);
        } catch (_) {
          size = 0;
        }
      }
      const total = (typeof reportedSize === 'number' && reportedSize > 0) ? reportedSize : size;
      if (!total || total < 8 * 1024) {
        return false;
      }
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const headBuf = new ArrayBuffer(64);
      const headRead = fs.readSync(file.fd, headBuf);
      const headLen = (typeof headRead === 'number' && headRead > 0) ? headRead : 0;
      const head = new Uint8Array(headBuf, 0, headLen);
      const hasFtyp = this.findAscii(head, 'ftyp');
      let hasMoov = false;
      const chunk = new ArrayBuffer(256 * 1024);
      let off = head.length;
      let scanned = 0;
      if (off < total) {
        while (off < total && off < (1024 * 1024)) {
          const n = fs.readSync(file.fd, chunk);
          const len = (typeof n === 'number' && n > 0) ? n : 0;
          if (len <= 0) break;
          const u8 = new Uint8Array(chunk, 0, len);
          if (this.findAscii(u8, 'moov')) { hasMoov = true; break; }
          off += len;
          scanned += len;
        }
      }
      if (!hasFtyp) {
        return false;
      }
      return true;
    } catch (err) {
      return false;
    } finally {
      if (file) {
        try { fs.closeSync(file); } catch (_) {}
      }
    }
  }

  private safeFileSize(path?: string): number {
    if (!path || path.length === 0) {
      return 0;
    }
    try {
      const statFs = fs.statSync(path);
      if (statFs && typeof statFs.size === 'number') {
        return statFs.size as number;
      }
    } catch (_) {}
    try {
      const st = fileio.statSync(path);
      return (st.size as number) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  private readVideoBytes(path?: string): Uint8Array | undefined {
    if (!path || path.length === 0) {
      return undefined;
    }
    let file: fs.File | undefined;
    try {
      let size = 0;
      try {
        const statFs = fs.statSync(path);
        size = statFs && typeof statFs.size === 'number' ? (statFs.size as number) : 0;
      } catch (statErr) {
        try {
          const st = fileio.statSync(path);
          size = st && typeof st.size === 'number' ? (st.size as number) : 0;
        } catch (fileioErr) {
          size = 0;
        }
      }
      if (!size || size <= 0) {
        return undefined;
      }
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const chunkSize = 256 * 1024;
      const out = new Uint8Array(size);
      const chunkBuffer = new ArrayBuffer(chunkSize);
      let offset = 0;
      while (offset < size) {
        const read = fs.readSync(file.fd, chunkBuffer);
        const len = (typeof read === 'number' && read > 0) ? read : 0;
        if (len <= 0) {
          break;
        }
        const chunkView = new Uint8Array(chunkBuffer, 0, len);
        out.set(chunkView, offset);
        offset += len;
      }
      if (offset <= 0) {
        return undefined;
      }
      if (offset < size) {
        const trimmed = new Uint8Array(offset);
        trimmed.set(out.subarray(0, offset), 0);
        return trimmed;
      }
      return out;
    } catch (err) {
      return undefined;
    } finally {
      if (file) {
        try { fs.closeSync(file); } catch (_) {}
      }
    }
  }

  private findAscii(buf: Uint8Array, needle: string): boolean {
    if (!buf || buf.length === 0 || !needle || needle.length === 0) return false;
    const n0 = needle.charCodeAt(0) & 0xFF;
    const n1 = needle.length > 1 ? (needle.charCodeAt(1) & 0xFF) : -1;
    const n2 = needle.length > 2 ? (needle.charCodeAt(2) & 0xFF) : -1;
    const n3 = needle.length > 3 ? (needle.charCodeAt(3) & 0xFF) : -1;
    for (let i = 0; i < buf.length; i++) {
      if (buf[i] !== n0) continue;
      if (needle.length === 1) return true;
      if (i + 1 < buf.length && buf[i+1] === n1) {
        if (needle.length === 2) return true;
        if (i + 2 < buf.length && buf[i+2] === n2) {
          if (needle.length === 3) return true;
          if (i + 3 < buf.length && buf[i+3] === n3) return true;
        }
      }
    }
    return false;
  }

  private indexOfFourcc(buf: Uint8Array, fourcc: string): number {
    if (!buf || buf.length === 0 || !fourcc || fourcc.length !== 4) {
      return -1;
    }
    const target = [
      fourcc.charCodeAt(0) & 0xFF,
      fourcc.charCodeAt(1) & 0xFF,
      fourcc.charCodeAt(2) & 0xFF,
      fourcc.charCodeAt(3) & 0xFF
    ];
    for (let i = 0; i <= buf.length - 4; i++) {
      if (buf[i] !== target[0]) continue;
      if (buf[i + 1] !== target[1]) continue;
      if (buf[i + 2] !== target[2]) continue;
      if (buf[i + 3] !== target[3]) continue;
      if (i >= 4) {
        const size = this.readUint32BE(buf, i - 4);
        if (size >= 12) {
          return i;
        }
      } else {
        return i;
      }
    }
    return -1;
  }

  private readUint32BE(buf: Uint8Array, offset: number): number {
    if (!buf || offset < 0 || offset + 4 > buf.length) {
      return 0;
    }
    return ((buf[offset] & 0xFF) * 0x1000000)
      + ((buf[offset + 1] & 0xFF) << 16)
      + ((buf[offset + 2] & 0xFF) << 8)
      + (buf[offset + 3] & 0xFF);
  }

  private readUint64BE(buf: Uint8Array, offset: number): number {
    if (!buf || offset < 0 || offset + 8 > buf.length) {
      return 0;
    }
    const high = this.readUint32BE(buf, offset);
    const low = this.readUint32BE(buf, offset + 4);
    return high * 4294967296 + low;
  }

  private writeUint32BE(buf: Uint8Array, offset: number, value: number): void {
    if (!buf || offset < 0 || offset + 4 > buf.length) {
      return;
    }
    let v = Math.floor(value);
    if (v < 0) v = 0;
    if (v > 0xFFFFFFFF) v = 0xFFFFFFFF;
    buf[offset] = (v >>> 24) & 0xFF;
    buf[offset + 1] = (v >>> 16) & 0xFF;
    buf[offset + 2] = (v >>> 8) & 0xFF;
    buf[offset + 3] = v & 0xFF;
  }

  private writeUint64BE(buf: Uint8Array, offset: number, value: number): void {
    if (!buf || offset < 0 || offset + 8 > buf.length) {
      return;
    }
    let v = Math.floor(value);
    if (v < 0) v = 0;
    if (v > Number.MAX_SAFE_INTEGER) v = Number.MAX_SAFE_INTEGER;
    const high = Math.floor(v / 4294967296);
    const low = v >>> 0;
    this.writeUint32BE(buf, offset, high);
    this.writeUint32BE(buf, offset + 4, low);
  }

  private patchMp4Durations(path: string, durationMs: number): void {
    if (!path || path.length === 0 || durationMs <= 0) {
      return;
    }
    let file: fs.File | undefined;
    try {
      const stat = fs.statSync(path);
      const size = stat && typeof stat.size === 'number' ? (stat.size as number) : 0;
      if (!size || size <= 0 || size > 16 * 1024 * 1024) {
        return;
      }
      file = fs.openSync(path, fs.OpenMode.READ_WRITE);
      const buffer = new ArrayBuffer(size);
      const read = fs.readSync(file.fd, buffer);
      const len = (typeof read === 'number' && read > 0) ? read : 0;
      if (len <= 0) {
        fs.closeSync(file);
        return;
      }
      const bytes = new Uint8Array(buffer, 0, len);
      let mvhdTimescale = 1000;
      let durationTicks = Math.max(1, Math.floor(durationMs));
      const mvhdIndex = this.indexOfFourcc(bytes, 'mvhd');
      if (mvhdIndex >= 0) {
        const version = bytes[mvhdIndex + 4];
        if (version === 0 && mvhdIndex + 24 <= bytes.length) {
          const ts = this.readUint32BE(bytes, mvhdIndex + 16);
          if (ts > 0) {
            mvhdTimescale = ts;
          }
          durationTicks = Math.max(1, Math.floor((durationMs * mvhdTimescale) / 1000));
          this.writeUint32BE(bytes, mvhdIndex + 16, mvhdTimescale);
          this.writeUint32BE(bytes, mvhdIndex + 20, durationTicks);
        } else if (version === 1 && mvhdIndex + 32 <= bytes.length) {
          const ts = this.readUint32BE(bytes, mvhdIndex + 20);
          if (ts > 0) {
            mvhdTimescale = ts;
          }
          const ticks64 = Math.max(1, Math.floor((durationMs * mvhdTimescale) / 1000));
          durationTicks = ticks64;
          this.writeUint32BE(bytes, mvhdIndex + 20, mvhdTimescale);
          this.writeUint64BE(bytes, mvhdIndex + 24, ticks64);
        }
      }
      const tkhdIndex = this.indexOfFourcc(bytes, 'tkhd');
      if (tkhdIndex >= 0) {
        const version = bytes[tkhdIndex + 4];
        const ticks = Math.max(1, durationTicks);
        if (version === 0 && tkhdIndex + 24 <= bytes.length) {
          this.writeUint32BE(bytes, tkhdIndex + 20, ticks);
        } else if (version === 1 && tkhdIndex + 40 <= bytes.length) {
          this.writeUint64BE(bytes, tkhdIndex + 28, ticks);
        }
      }
      const mdhdIndex = this.indexOfFourcc(bytes, 'mdhd');
      if (mdhdIndex >= 0) {
        const version = bytes[mdhdIndex + 4];
        const desiredTimescale = 1000;
        const ticks = Math.max(1, Math.floor((durationMs * desiredTimescale) / 1000));
        if (version === 0 && mdhdIndex + 20 <= bytes.length) {
          this.writeUint32BE(bytes, mdhdIndex + 12, desiredTimescale);
          this.writeUint32BE(bytes, mdhdIndex + 16, ticks);
        } else if (version === 1 && mdhdIndex + 32 <= bytes.length) {
          this.writeUint32BE(bytes, mdhdIndex + 20, desiredTimescale);
          this.writeUint64BE(bytes, mdhdIndex + 24, ticks);
        }
      }
      fs.closeSync(file);
      // 确保只写入实际读取的数据，而不是整个 buffer（可能包含未初始化数据）
      // 创建一个新的 ArrayBuffer 只包含实际读取的数据，避免写入未初始化数据
      const trimmed = new Uint8Array(len);
      trimmed.set(bytes.subarray(0, len), 0);
      const dataToWrite = trimmed.buffer;
      const out = fs.openSync(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      const written = fs.writeSync(out.fd, dataToWrite);
      fs.fsyncSync(out.fd);
      fs.closeSync(out);
      // 验证patch是否成功：重新读取文件并检查duration（需要读取整个文件，因为mvhd可能在文件末尾）
      try {
        const verifyFile = fs.openSync(path, fs.OpenMode.READ_ONLY);
        const verifySize = bytes.length;
        const verifyBuffer = new ArrayBuffer(verifySize);
        const verifyRead = fs.readSync(verifyFile.fd, verifyBuffer);
        fs.closeSync(verifyFile);
        if (verifyRead && typeof verifyRead === 'number' && verifyRead > 0) {
          const verifyBytes = new Uint8Array(verifyBuffer, 0, verifyRead);
          const verifyMvhdIndex = this.indexOfFourcc(verifyBytes, 'mvhd');
          if (verifyMvhdIndex >= 0) {
            const verifyVersion = verifyBytes[verifyMvhdIndex + 4];
            let verifyDurationMs = -1;
            if (verifyVersion === 0 && verifyMvhdIndex + 24 <= verifyBytes.length) {
              const verifyTs = this.readUint32BE(verifyBytes, verifyMvhdIndex + 16);
              const verifyDuration = this.readUint32BE(verifyBytes, verifyMvhdIndex + 20);
              if (verifyTs > 0) {
                verifyDurationMs = Math.floor((verifyDuration * 1000) / verifyTs);
              }
            } else if (verifyVersion === 1 && verifyMvhdIndex + 32 <= verifyBytes.length) {
              const verifyTs = this.readUint32BE(verifyBytes, verifyMvhdIndex + 20);
              const verifyDuration64 = this.readUint64BE(verifyBytes, verifyMvhdIndex + 24);
              if (verifyTs > 0) {
                verifyDurationMs = Math.floor((verifyDuration64 * 1000) / verifyTs);
              }
            }
            const expectedDurationMs = durationMs;
            const diffMs = Math.abs(verifyDurationMs - expectedDurationMs);
            if (diffMs > 100) {
              replayWarn('ReplayEnvelopeSender', 'mp4 patch verification mismatch path=' + path + ' expected=' + String(expectedDurationMs) + 'ms verified=' + String(verifyDurationMs) + 'ms diff=' + String(diffMs) + 'ms');
            } else {
              replayInfo('ReplayEnvelopeSender', 'mp4 durations patched path=' + path + ' durationMs=' + String(durationMs) + ' written=' + String(written) + ' size=' + String(bytes.length) + ' mvhdIndex=' + String(mvhdIndex >= 0 ? mvhdIndex : -1) + ' tkhdIndex=' + String(tkhdIndex >= 0 ? tkhdIndex : -1) + ' mdhdIndex=' + String(mdhdIndex >= 0 ? mdhdIndex : -1) + ' verifiedDurationMs=' + String(verifyDurationMs) + 'ms');
            }
          } else {
            replayWarn('ReplayEnvelopeSender', 'mp4 patch verification: mvhd not found in patched file path=' + path);
          }
        }
      } catch (verifyErr) {
        try {
          replayWarn('ReplayEnvelopeSender', 'mp4 patch verification failed path=' + path + ' err=' + String(verifyErr));
        } catch (_) {}
      }
    } catch (err) {
      try {
        if (file) {
          fs.closeSync(file);
        }
      } catch (_) {}
      try { replayWarn('ReplayEnvelopeSender', 'patchMp4Durations failed path=' + String(path) + ' err=' + String(err)); } catch (_) {}
    }
  }

  // 将 ActivityPayload 显式转换为 Record<string,Object>
  private toActivityObject(p: ActivityPayload): Object {
    return new ActivityPayloadRecord(p.note) as Object;
  }

  private buildRecordingBytes(payload: ReplayPayload, events: Array<RRWebEventJson>): Uint8Array {
    const segment: number = payload.segment_id ?? 0;
    const recHead = { segment_id: segment } as ReplayRecording;
    const headBytes = this.encodeUtf8(JSON.stringify(recHead));
    const newline = this.encodeUtf8('\n');
    const eventsBytes = this.encodeUtf8(JSON.stringify(events));
    return this.concat([headBytes, newline, eventsBytes]);
  }

  private normalizeReplayPayload(payload: ReplayPayload): ReplayPayload {
    const out: ReplayPayload = { sessionId: payload.sessionId, events: payload.events };
    if (payload.replay_id) out.replay_id = payload.replay_id;
    if (typeof payload.segment_id === 'number') out.segment_id = payload.segment_id;
    if (payload.started_at) out.started_at = payload.started_at;
    if (payload.finished_at) out.finished_at = payload.finished_at;
    if (payload.trace_ids) out.trace_ids = payload.trace_ids;
    if (payload.error_ids) out.error_ids = payload.error_ids;
    if (payload.urls) out.urls = payload.urls;
    if (payload.replay_type) out.replay_type = payload.replay_type;
    if (payload.videoPath) out.videoPath = payload.videoPath;
    if (typeof payload.videoSizeBytes === 'number') out.videoSizeBytes = payload.videoSizeBytes;
    if (typeof payload.videoWidth === 'number') out.videoWidth = payload.videoWidth;
    if (typeof payload.videoHeight === 'number') out.videoHeight = payload.videoHeight;
    if (typeof payload.videoFrameRate === 'number') out.videoFrameRate = payload.videoFrameRate;
    if (!out.replay_id && payload.replay_id) {
      out.replay_id = payload.replay_id;
    }
    // 规范化 replay_id 为 36 位 UUID (带连字符)，与 Error Event 保持一致
    const isValidId = (s: string | undefined): boolean => !!s && /^[0-9a-f]{32}$/.test(s);
    if (!out.replay_id) out.replay_id = payload.replay_id ?? payload.sessionId;
    
    if (out.replay_id) {
      const noDash = out.replay_id.replace(/-/g, '');
      if (/^[0-9a-fA-F]{32}$/.test(noDash)) {
        // Format as standard UUID (hyphenated)
        const low = noDash.toLowerCase();
        out.replay_id = low.substring(0, 8) + '-' + low.substring(8, 12) + '-' + low.substring(12, 16) + '-' + low.substring(16, 20) + '-' + low.substring(20);
      } else {
        out.replay_id = this.normalizeReplayId(out.replay_id);
      }
    }
    
    if (typeof out.segment_id !== 'number') out.segment_id = 0;
    try {
      let minTs: number | undefined; let maxTs: number | undefined;
      for (let i = 0; i < payload.events.length; i++) {
        const ev = payload.events[i]; if (!ev) continue;
        const arr = ev.data as Array<HasTimestamp>; if (!Array.isArray(arr)) continue;
        for (let j = 0; j < arr.length; j++) {
          const t = arr[j]?.timestamp;
          if (typeof t === 'number') { if (minTs === undefined || t < minTs) minTs = t; if (maxTs === undefined || t > maxTs) maxTs = t; }
        }
      }
      const nowSec = Math.floor(Date.now() / 1000);
      const startSec = minTs !== undefined ? Math.floor(minTs / 1000) : nowSec;
      const endSec = maxTs !== undefined ? Math.floor(maxTs / 1000) : nowSec;
      if (!out.started_at) out.started_at = new Date(startSec * 1000).toISOString();
      if (!out.finished_at) out.finished_at = new Date(endSec * 1000).toISOString();
      out.replay_start_timestamp = startSec;
      out.timestamp = endSec <= startSec ? (startSec + 1) : endSec;
      out.platform = 'android';
      if (!out.replay_type) out.replay_type = 'session';
      if (!out.urls || out.urls.length === 0) out.urls = ['/'];
    } catch (_) {}
    return out;
  }

  private buildMsgpackForReplay(replayEventJson: Uint8Array, replayRecordingJson: Uint8Array, replayVideoBytes?: Uint8Array): Uint8Array {
    const entries: Array<MsgpackEntry> = [];
    entries.push({ key: 'replay_event', value: replayEventJson });
    entries.push({ key: 'replay_recording', value: replayRecordingJson });
    if (replayVideoBytes && replayVideoBytes.length > 0) entries.push({ key: 'replay_video', value: replayVideoBytes });
    const parts: Array<Uint8Array> = []; const size = entries.length;
    if (size <= 15) parts.push(new Uint8Array([0x80 | size]));
    else if (size <= 0xffff) parts.push(new Uint8Array([0xDE, (size >> 8) & 0xff, size & 0xff]));
    else parts.push(new Uint8Array([0xDF, (size >> 24) & 0xff, (size >> 16) & 0xff, (size >> 8) & 0xff, size & 0xff]));
    for (let i = 0; i < entries.length; i++) { const e = entries[i]; parts.push(this.encodeMsgpackStr(e.key)); parts.push(this.encodeMsgpackBin(e.value)); }
    return this.concat(parts);
  }

  private encodeMsgpackStr(s: string): Uint8Array {
    // Android 对齐：字符串 key 总是使用 str8 (0xD9)，即使长度 <= 31
    const bytes = this.encodeUtf8(s); const len = bytes.length;
    if (len <= 0xff) { const out = new Uint8Array(2 + len); out[0] = 0xD9; out[1] = len & 0xff; out.set(bytes, 2); return out; }
    else if (len <= 0xffff) { const out = new Uint8Array(3 + len); out[0] = 0xDA; out[1] = (len >> 8) & 0xff; out[2] = len & 0xff; out.set(bytes, 3); return out; }
    else { const out = new Uint8Array(5 + len); out[0] = 0xDB; out[1] = (len >> 24) & 0xff; out[2] = (len >> 16) & 0xff; out[3] = (len >> 8) & 0xff; out[4] = len & 0xff; out.set(bytes, 5); return out; }
  }

  private encodeMsgpackBin(bytes: Uint8Array): Uint8Array {
    // Android 对齐：二进制 value 总是使用 bin32 (0xC6)，即使长度很小
    // We will always use the 4 bytes data length for simplicity.
    const len = bytes.length;
    const out = new Uint8Array(5 + len);
    out[0] = 0xC6;
    out[1] = (len >> 24) & 0xff;
    out[2] = (len >> 16) & 0xff;
    out[3] = (len >> 8) & 0xff;
    out[4] = len & 0xff;
    out.set(bytes, 5);
    return out;
  }

  private uint8ArrayToBase64(bytes: Uint8Array): string {
    const table: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let out = ''; let i = 0;
    while (i < bytes.length) {
      const b0 = bytes[i++] ?? 0; const b1 = i < bytes.length ? bytes[i++] : NaN; const b2 = i < bytes.length ? bytes[i++] : NaN;
      const c0 = b0 >> 2;
      const c1 = ((b0 & 0x03) << 4) | (isNaN(b1) ? 0 : ((b1 as number) >> 4));
      const c2 = isNaN(b1) ? 64 : ((((b1 as number) & 0x0f) << 2) | (isNaN(b2) ? 0 : (((b2 as number) >> 6))));
      const c3 = isNaN(b2) ? 64 : (((b2 as number) & 0x3f));
      out += table.charAt(c0); out += table.charAt(c1); out += c2 === 64 ? '=' : table.charAt(c2); out += c3 === 64 ? '=' : table.charAt(c3);
    }
    return out;
  }

  private buildEndpointFromDsn(dsn: string): string {
    try {
      const m = dsn.match(/^https?:\/\/([^@]+)@([^\/]+)\/(\d+)(?:\/?|.*)$/);
      if (m) {
        const publicKey = m[1]; const host = m[2]; const projectId = m[3];
        return `https://${host}/api/${projectId}/envelope/?sentry_key=${publicKey}&sentry_version=7`;
      }
    } catch (_) {}
    return dsn;
  }

  private generateUuidV4(): string {
    const hex: string[] = []; for (let i = 0; i < 16; i++) { const byteVal: number = Math.floor(Math.random() * 256); const h = byteVal.toString(16); hex.push(h.length === 1 ? ('0' + h) : h); }
    return hex.join('').toLowerCase();
  }
}

export default ReplayEnvelopeSender;


