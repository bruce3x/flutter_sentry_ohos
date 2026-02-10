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
import { HarmonyLogger } from './HarmonyUtilsAdapter';
import { Envelope } from './Types';
import { Breadcrumb as CoreBreadcrumb } from '../sentry/Breadcrumb';
import { collectRuntimeContext, collectDeviceContext } from './Context';
import { TraceManager } from './TraceManager';
import { SpanTimer } from './Performance';

type Primitive = string | number | boolean | null | undefined;

export interface HttpTransportOptions {
  endpointUrl: string;
  headers?: Record<string, string>;
  connectTimeoutMs?: number;
  readTimeoutMs?: number;
  maxRetries?: number;
  retryBaseDelayMs?: number;
  debug?: boolean;
}

interface QueueItem {
  envelope: Envelope;
  attempt: number;
}

interface HttpRequestOptions {
  method: http.RequestMethod;
  header?: Record<string, string>;
  extraData?: string;
  connectTimeout?: number;
  readTimeout?: number;
}

interface HttpResponseLite {
  responseCode: number;
  result?: string;
}

// 明确 Span 属性类型（不使用索引签名，传递为 Object）
class HttpSendSpanAttrs { op: string; url: string; constructor(op: string, url: string) { this.op = op; this.url = url; } }
class HttpSendOkAttrs { http_status: number; constructor(status: number) { this.http_status = status; } }
class HttpSendFailAttrs { http_error: number; constructor() { this.http_error = 1; } }

export class HttpTransportImpl {
  private opts: HttpTransportOptions;
  private queue: Array<QueueItem> = [];
  private sending: boolean = false;

  constructor(opts: HttpTransportOptions) {
    this.opts = opts;
  }

  async send(envelope: Envelope): Promise<void> {
    const item: QueueItem = { envelope: envelope, attempt: 0 };
    this.queue.push(item);
    if (!this.sending) {
      this.sending = true;
      await this.drain();
    }
  }

  private async drain(): Promise<void> {
    while (this.queue.length > 0) {
      const item = this.queue[0];
      const ok = await this.trySend(item);
      if (ok) {
        this.queue.shift();
      } else {
        const maxR = (this.opts.maxRetries !== undefined) ? this.opts.maxRetries : 3;
        if (item.attempt >= maxR) {
          this.queue.shift();
        } else {
          item.attempt = item.attempt + 1;
          const base = (this.opts.retryBaseDelayMs !== undefined) ? this.opts.retryBaseDelayMs : 500;
          const waitMs = base * (item.attempt + 1);
          await this.sleep(waitMs);
        }
      }
    }
    this.sending = false;
  }

  private async trySend(item: QueueItem): Promise<boolean> {
    const url = this.opts.endpointUrl;
    const client = http.createHttp();
    const body = this.serializeEnvelope(item.envelope);

    const headers: Record<string, string> = this.opts.headers ? this.opts.headers : {};
    headers['Content-Type'] = 'application/json';

    const connectTimeout = (this.opts.connectTimeoutMs !== undefined) ? this.opts.connectTimeoutMs : 5000;
    const readTimeout = (this.opts.readTimeoutMs !== undefined) ? this.opts.readTimeoutMs : 8000;

    const options: HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: body,
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
    };

    try {
      // 记录网络 span（发送 envelope）
      const tm = TraceManager.get();
      const attrs = new HttpSendSpanAttrs('http.client', url);
      const timer = new SpanTimer('http.send', attrs as Object);
      const response = await (client.request(url, options) as Promise<HttpResponseLite>);
      const endOk = new HttpSendOkAttrs(response.responseCode);
      tm.addSpan(timer.end(endOk as Object));
      if (this.opts.debug) {
        HarmonyLogger.info('HTTP send', 'code=' + String(response.responseCode));
      }
      client.destroy();
      return response.responseCode >= 200 && response.responseCode < 300;
    } catch (e) {
      try { client.destroy(); } catch (_) {}
      // 失败也记录一次 span
      try {
        const tm = TraceManager.get();
        const attrsFail = new HttpSendSpanAttrs('http.client', url);
        const timer = new SpanTimer('http.send', attrsFail as Object);
        const endFail = new HttpSendFailAttrs();
        tm.addSpan(timer.end(endFail as Object));
      } catch (_) {}
      if (this.opts.debug) HarmonyLogger.warn('HTTP send failed', 'attempt=' + String(item.attempt));
      return false;
    }
  }

  private async sleep(ms: number): Promise<void> {
    await new Promise<void>((resolve) => {
      setTimeout(() => resolve(), ms);
    });
  }

  private serializeEnvelope(env: Envelope): string {
    try {
      if (env.type === 'anr') {
        // 将 anr Envelope 映射到接近 Sentry Android 的事件结构
        interface HttpThread { name: string; state: string }
        interface HttpExceptionMechanism { type: string; handled: boolean }
        interface HttpExceptionValue { type: string; value: string; mechanism: HttpExceptionMechanism }
        interface HttpException { values: Array<HttpExceptionValue> }
        interface HttpOsContext { name: string; version?: string; build?: string; id?: string; kernel_version?: string }
        interface HttpRuntimeContext { networkType?: string; batteryLevel?: number; isCharging?: boolean; memoryUsedMb?: number; memoryTotalMb?: number; foregroundPage?: string; online?: boolean; screenWidthPx?: number; screenHeightPx?: number; screenDpi?: number; screenDensity?: number; storageTotalGb?: number; storageFreeGb?: number; cpuFrequencyMHz?: number; freeMemoryMb?: number; lowMemory?: boolean }
        interface HttpContexts { device: Record<string, Primitive>; app: Record<string, Primitive>; os: HttpOsContext; runtime?: HttpRuntimeContext }
        interface HttpTags { is_foreground?: boolean }
        interface HttpExtra { blockedForMs?: number; lastBreadcrumb?: CoreBreadcrumb }
        interface HttpAnrEvent {
          timestamp: string;
          level: 'error';
          platform: 'ohos';
          logger: 'sentry-ohos';
          release?: string;
          environment?: string;
          fingerprint: Array<string>;
          tags: HttpTags;
          contexts: HttpContexts;
          breadcrumbs: Array<CoreBreadcrumb>;
          threads: Array<HttpThread>;
          exception: HttpException;
          extra: HttpExtra;
          session?: object;
          type: 'event';
        }
        interface HttpAnrData {
          blockedForMs?: number;
          isInForeground?: boolean;
          lastBreadcrumb?: CoreBreadcrumb;
          threads?: Array<HttpThread>;
        }
        const rawData = env.data as object;
        const data = rawData as HttpAnrData;
        const osVersionPrimitive = env.device['osVersion'];
        const osVersion = typeof osVersionPrimitive === 'string' ? osVersionPrimitive : undefined;
        const mainThread: HttpThread = { name: 'main', state: 'blocked' };
        const r = collectRuntimeContext();
        const runtimeCtx: HttpRuntimeContext = {
          networkType: r.networkType,
          batteryLevel: r.batteryLevel,
          isCharging: r.isCharging,
          memoryUsedMb: r.memoryUsedMb,
          memoryTotalMb: r.memoryTotalMb,
          foregroundPage: r.foregroundPage,
          online: r.online,
          screenWidthPx: r.screenWidthPx,
          screenHeightPx: r.screenHeightPx,
          screenDpi: r.screenDpi,
          screenDensity: r.screenDensity,
          storageTotalGb: r.storageTotalGb,
          storageFreeGb: r.storageFreeGb,
          cpuFrequencyMHz: r.cpuFrequencyMHz,
          freeMemoryMb: r.freeMemoryMb,
          lowMemory: r.lowMemory,
        };
        // 使用与 HttpTransport.serializeEvent 相同的设备上下文标准化逻辑，确保字段完整对齐
        const deviceBase = (env.device as Record<string, Primitive>) || {};
        const deviceCollected = collectDeviceContext();
        // 合并 collected 和 base
        const deviceMerged: Record<string, Primitive> = {};
        const mergeInto = (dst: Record<string, Primitive>, src: Record<string, Primitive>) => {
          const keys = Object.keys(src);
          for (let i = 0; i < keys.length; i++) {
            const k = keys[i];
            const v = src[k];
            if (v !== undefined && v !== null) dst[k] = v as Primitive;
          }
        };
        mergeInto(deviceMerged, deviceCollected);
        mergeInto(deviceMerged, deviceBase);

        // 标准化 device 字段（对齐 HttpTransport.serializeEvent 逻辑）
        type PrimitiveOut = string | number | boolean;
        interface DeviceCtxInCamel { manufacturer?: string; brand?: string; family?: string; model?: string; modelId?: string; arch?: string; archs?: Array<string> | string; chipset?: string; batteryLevel?: number; isCharging?: boolean; isOnline?: boolean; orientation?: string; simulator?: boolean; memorySize?: number; freeMemory?: number; storageSize?: number; freeStorage?: number; screenDensity?: number; screenDpi?: number; bootTime?: string; timezone?: string; id?: string; locale?: string; connectionType?: string; batteryTemperature?: number; processorCount?: number; processorFrequency?: number; osVersion?: string; build?: string; versionId?: string; name?: string; screen_width_pixels?: number; screen_height_pixels?: number; upload_bandwidth?: number; download_bandwidth?: number; vpn_active?: boolean }
        const devRaw = deviceMerged as DeviceCtxInCamel;
        const deviceOut: Record<string, Object> = {};

        // 基础字段映射（camelCase → snake_case，兼容 snake_case）
        if (typeof devRaw.manufacturer === 'string') deviceOut['manufacturer'] = devRaw.manufacturer;
        if (typeof devRaw.brand === 'string') deviceOut['brand'] = devRaw.brand;
        if (typeof devRaw.family === 'string') deviceOut['family'] = devRaw.family;
        if (typeof devRaw.model === 'string') deviceOut['model'] = devRaw.model;
        if (typeof devRaw.modelId === 'string') deviceOut['model_id'] = devRaw.modelId;
        if (typeof devRaw.id === 'string') deviceOut['id'] = devRaw.id;
        if (typeof devRaw.locale === 'string') deviceOut['locale'] = devRaw.locale;
        if (typeof devRaw.timezone === 'string') deviceOut['timezone'] = devRaw.timezone;
        if (typeof devRaw.arch === 'string') deviceOut['arch'] = devRaw.arch;
        if (Array.isArray(devRaw.archs)) deviceOut['archs'] = devRaw.archs as Object;
        if (typeof devRaw.archs === 'string') {
          const arr = (devRaw.archs as string).split(',');
          deviceOut['archs'] = arr as Object;
        }
        if (typeof devRaw.chipset === 'string') deviceOut['chipset'] = devRaw.chipset;
        if (typeof devRaw.batteryLevel === 'number') deviceOut['battery_level'] = devRaw.batteryLevel;
        if (typeof devRaw.batteryTemperature === 'number') deviceOut['battery_temperature'] = devRaw.batteryTemperature;
        if (typeof devRaw.isCharging === 'boolean') deviceOut['charging'] = devRaw.isCharging;
        if (typeof devRaw.isOnline === 'boolean') deviceOut['online'] = devRaw.isOnline;
        if (typeof devRaw.connectionType === 'string') deviceOut['connection_type'] = devRaw.connectionType;
        if (typeof devRaw.orientation === 'string') deviceOut['orientation'] = devRaw.orientation;
        if (typeof devRaw.simulator === 'boolean') deviceOut['simulator'] = devRaw.simulator;
        if (typeof devRaw.memorySize === 'number') deviceOut['memory_size'] = devRaw.memorySize;
        if (typeof devRaw.freeMemory === 'number') deviceOut['free_memory'] = devRaw.freeMemory;
        if (typeof devRaw.storageSize === 'number') deviceOut['storage_size'] = devRaw.storageSize;
        if (typeof devRaw.freeStorage === 'number') deviceOut['free_storage'] = devRaw.freeStorage;
        if (typeof devRaw.screenDensity === 'number') deviceOut['screen_density'] = devRaw.screenDensity;
        if (typeof devRaw.screenDpi === 'number') deviceOut['screen_dpi'] = devRaw.screenDpi;
        if (typeof devRaw.screen_width_pixels === 'number') deviceOut['screen_width_pixels'] = devRaw.screen_width_pixels;
        if (typeof devRaw.screen_height_pixels === 'number') deviceOut['screen_height_pixels'] = devRaw.screen_height_pixels;
        if (typeof devRaw.upload_bandwidth === 'number') deviceOut['upload_bandwidth'] = devRaw.upload_bandwidth;
        if (typeof devRaw.download_bandwidth === 'number') deviceOut['download_bandwidth'] = devRaw.download_bandwidth;
        if (typeof devRaw.vpn_active === 'boolean') deviceOut['vpn_active'] = devRaw.vpn_active;
        if (typeof devRaw.bootTime === 'string') deviceOut['boot_time'] = devRaw.bootTime;
        if (typeof devRaw.processorCount === 'number') deviceOut['processor_count'] = devRaw.processorCount;
        if (typeof devRaw.processorFrequency === 'number') deviceOut['processor_frequency'] = devRaw.processorFrequency;
        if (typeof devRaw.osVersion === 'string') deviceOut['osVersion'] = devRaw.osVersion;
        if (typeof devRaw.build === 'string') deviceOut['build'] = devRaw.build;
        if (typeof devRaw.versionId === 'string') deviceOut['versionId'] = devRaw.versionId;
        if (typeof devRaw.name === 'string') deviceOut['name'] = devRaw.name;

        // 从 runtime context 补充字段（如果 device 中没有）
        if (runtimeCtx) {
          if (!deviceOut['screen_width_pixels'] && typeof runtimeCtx.screenWidthPx === 'number') deviceOut['screen_width_pixels'] = runtimeCtx.screenWidthPx;
          if (!deviceOut['screen_height_pixels'] && typeof runtimeCtx.screenHeightPx === 'number') deviceOut['screen_height_pixels'] = runtimeCtx.screenHeightPx;
          if (!deviceOut['battery_level'] && typeof runtimeCtx.batteryLevel === 'number') deviceOut['battery_level'] = runtimeCtx.batteryLevel;
          if (deviceOut['charging'] === undefined && typeof runtimeCtx.isCharging === 'boolean') deviceOut['charging'] = runtimeCtx.isCharging;
          if (deviceOut['online'] === undefined && typeof runtimeCtx.online === 'boolean') deviceOut['online'] = runtimeCtx.online;
          if (!deviceOut['memory_size'] && typeof runtimeCtx.memoryTotalMb === 'number') deviceOut['memory_size'] = Math.floor(runtimeCtx.memoryTotalMb * 1024 * 1024);
          if (!deviceOut['free_memory'] && typeof runtimeCtx.memoryTotalMb === 'number' && typeof runtimeCtx.memoryUsedMb === 'number') {
            const freeMb = runtimeCtx.memoryTotalMb - runtimeCtx.memoryUsedMb;
            if (freeMb >= 0) deviceOut['free_memory'] = Math.floor(freeMb * 1024 * 1024);
          }
          if (!deviceOut['storage_size'] && typeof runtimeCtx.storageTotalGb === 'number') deviceOut['storage_size'] = Math.floor(runtimeCtx.storageTotalGb * 1024 * 1024 * 1024);
          if (!deviceOut['free_storage'] && typeof runtimeCtx.storageFreeGb === 'number') deviceOut['free_storage'] = Math.floor(runtimeCtx.storageFreeGb * 1024 * 1024 * 1024);
          if (!deviceOut['screen_dpi'] && typeof runtimeCtx.screenDpi === 'number') deviceOut['screen_dpi'] = runtimeCtx.screenDpi;
          if (!deviceOut['screen_density'] && typeof runtimeCtx.screenDensity === 'number') deviceOut['screen_density'] = runtimeCtx.screenDensity;
          if (!deviceOut['connection_type'] && typeof runtimeCtx.networkType === 'string') deviceOut['connection_type'] = runtimeCtx.networkType;
          if (!deviceOut['processor_frequency'] && typeof runtimeCtx.cpuFrequencyMHz === 'number') deviceOut['processor_frequency'] = runtimeCtx.cpuFrequencyMHz;
          if (!deviceOut['orientation'] && typeof runtimeCtx.screenWidthPx === 'number' && typeof runtimeCtx.screenHeightPx === 'number') {
            deviceOut['orientation'] = runtimeCtx.screenWidthPx < runtimeCtx.screenHeightPx ? 'portrait' : 'landscape';
          }
        }

        // 默认值回退
        if (!deviceOut['family'] && typeof deviceOut['model'] === 'string') deviceOut['family'] = deviceOut['model'] as string;
        if (!deviceOut['model_id'] && typeof deviceOut['model'] === 'string') deviceOut['model_id'] = deviceOut['model'] as string;
        if (deviceOut['simulator'] === undefined) deviceOut['simulator'] = false;
        if (deviceOut['battery_temperature'] === undefined) deviceOut['battery_temperature'] = 28;

        const event: HttpAnrEvent = {
          timestamp: env.timestamp,
          level: 'error',
          platform: 'ohos',
          logger: 'sentry-ohos',
          release: env.release,
          environment: env.environment,
          fingerprint: ['ANR'],
          tags: ((): Record<string, string> => {
            const tags: Record<string, string> = {};
            if (typeof data.isInForeground === 'boolean') tags['is_foreground'] = data.isInForeground ? 'true' : 'false';
            // 补充 device/os 相关 tags（对齐 serializeEvent）
            if (typeof deviceOut['model'] === 'string') tags['device'] = String(deviceOut['model']);
            if (typeof deviceOut['osVersion'] === 'string') {
              tags['os'] = `OpenHarmony ${deviceOut['osVersion']}`;
              tags['os.name'] = 'OpenHarmony';
            }
            return tags;
          })(),
          contexts: {
            device: deviceOut as Record<string, Primitive>,
            app: env.app,
            os: ((): HttpOsContext => {
              const os: HttpOsContext = { name: 'OpenHarmony' };
              if (typeof deviceOut['osVersion'] === 'string') {
                os.version = String(deviceOut['osVersion']);
              }
              if (typeof deviceOut['build'] === 'string') {
                os.build = String(deviceOut['build']);
              }
              if (typeof deviceOut['versionId'] === 'string') {
                os.id = String(deviceOut['versionId']);
              }
              // 尝试从 device 获取 kernel_version（若存在）
              try {
                const kv = (deviceBase as Record<string, Primitive>)['kernelVersion'];
                if (typeof kv === 'string') {
                  os.kernel_version = kv;
                }
              } catch (_) {}
              return os;
            })(),
            runtime: runtimeCtx,
          },
          breadcrumbs: env.breadcrumbs as Array<CoreBreadcrumb>,
          threads: data.threads ? data.threads : [ mainThread ],
          exception: {
            values: [
              {
                type: 'ANR',
                value: 'Application Not Responding',
                mechanism: { type: 'ANR', handled: false },
              },
            ],
          },
          extra: {
            blockedForMs: typeof data.blockedForMs === 'number' ? data.blockedForMs : undefined,
            lastBreadcrumb: data.lastBreadcrumb ? data.lastBreadcrumb : undefined,
          },
          session: env.session,
          type: 'event',
        };
        return JSON.stringify(event);
      }
    } catch (e) {
      if (this.opts.debug) HarmonyLogger.warn('ANR serialize failed, fallback raw');
    }
    // 其它类型保持原样
    return JSON.stringify(env);
  }
}


