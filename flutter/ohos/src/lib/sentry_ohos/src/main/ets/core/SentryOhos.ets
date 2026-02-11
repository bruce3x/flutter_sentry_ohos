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

import { HarmonyLogger, getAppInfoSafe, getDeviceInfoSafe } from './HarmonyUtilsAdapter';
import { installGlobalErrorHandler } from './GlobalError';
import { SpanTimer, SpanContext } from './Performance';
import { SessionState, SessionTracker } from './Session';
import { AppStartMonitor } from './AppStart';
import { AnrMonitor, AnrThread } from './Anr';
import { HttpTransportImpl, HttpTransportOptions } from './HttpTransportImpl';
import { collectDeviceContext, collectAppContext, collectRuntimeContext, getKernelVersion, getProcessorCount, getLocaleTimezone, shouldSample, detectRooted } from './Context';
import { Envelope } from './Types';
import { InternalSentrySdk } from './InternalSentrySdk';
import { ViewHierarchyProcessor } from './ViewHierarchyProcessor';
import common from '@ohos.app.ability.common';
import { startReplay, stopReplay, getReplayId, captureReplayOnError as captureReplayOnErrorApi, uploadReplay as uploadReplayApi } from '../sentry_ohos_replay/api';
import { SentryLevel } from '../sentry/SentryLevel';
import { Sentry } from '../sentry/Sentry';
import { Hub } from '../sentry/Hub';
import type { AttachmentSpec } from '../sentry/HttpTransport';
import { BreadcrumbStore } from '../sentry/Breadcrumb';
import { AbilityLifecycleBreadcrumbs } from './AbilityLifecycleBreadcrumbs';
import { SentryOptions } from '../sentry/SentryOptions';
import { SentryOhosOptions, SentryOhosOptionsInit } from './SentryOhosOptions';
import { Mechanism } from '../sentry/Mechanism';
import { User } from '../sentry/User';
import { SentryEvent } from '../sentry/SentryEvent';
import { SentryTransaction } from '../sentry/SentryEvent';
import { replayInfo } from '../sentry_ohos_replay/ReplayLogger';
import { Breadcrumb as SdkBreadcrumb } from '../sentry/Breadcrumb';
import { Device } from '../sentry/Device'
import { SentryException } from '../sentry/SentryException';
import { SentryStackTrace } from '../sentry/SentryStackTrace';
import { FileEnvelopeCache } from '../sentry/Cache';
import { SentryStackFrame } from '../sentry/SentryStackFrame';
import { SentryThread } from '../sentry/SentryThread';
import { Span as SdkSpan } from '../sentry/Span';
import { TraceManager } from './TraceManager';
import {AutoBreadcrumbs} from '../core/AutoBreadcrumbs'
import hiAppEvent from '@ohos.hiviewdfx.hiAppEvent';
import { UserInteractionIntegration } from './UserInteractionIntegration';
import { FramesMonitor } from './Frames';
// HTTP 埋点封装移动至 HttpClient.ets，避免核心类过重


type Primitive = string | number | boolean | null | undefined;
type CoreBreadcrumb = SdkBreadcrumb;

// 顶层接口：runtime 上下文输出，避免对字段使用索引式赋值
interface RuntimeContextOut {
  networkType?: string;
  batteryLevel?: number;
  isCharging?: boolean;
  memoryUsedMb?: number;
  memoryTotalMb?: number;
  foregroundPage?: string;
  bootTime?: string;
  arch?: string;
  cpuFrequencyMHz?: number;
}

class ViewScreenshotContext {
  path: string;
  constructor(path: string) { this.path = path; }
}

function mapCoreLevelToSentryLevel(level: SentryLevel | 'debug' | 'info' | 'warning' | 'error' | undefined): SentryLevel | undefined {
  if (level === undefined) return undefined;
  switch (level) {
    case SentryLevel.Debug:
    case 'debug':
      return SentryLevel.Debug;
    case SentryLevel.Info:
    case 'info':
      return SentryLevel.Info;
    case SentryLevel.Warning:
    case 'warning':
      return SentryLevel.Warning;
    case SentryLevel.Error:
    case 'error':
      return SentryLevel.Error;
    case SentryLevel.Fatal:
      return SentryLevel.Fatal;
    default:
      return undefined;
  }
}

function toSdkBreadcrumb(c: CoreBreadcrumb): SdkBreadcrumb {
  let dataStrings: Record<string, string> | undefined = undefined;
  if (c.data) {
    dataStrings = {};
    const keys = Object.keys(c.data);
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      const v = (c.data as Record<string, Primitive>)[k];
      dataStrings[k] = v === null || v === undefined ? String(v) : (typeof v === 'string' ? v : String(v));
    }
  }
  const sdkLevel = mapCoreLevelToSentryLevel(c.level);
  const bc = new SdkBreadcrumb();
  bc.timestamp = c.timestamp;
  bc.message = c.message;
  bc.category = c.category;
  bc.level = sdkLevel;
  bc.data = dataStrings;
  return bc;
}

// 兼容旧命名，保留类型别名
export type OhosSentryOptions = SentryOhosOptions;

interface Transport {
  send(payload: Envelope): Promise<void>;
}

interface MessageData {
  message: string;
  level: 'info' | 'warning' | 'error';
  extra?: Record<string, Primitive>;
}

interface ExceptionData {
  name: string;
  message: string;
  stack?: string;
  extra?: Record<string, Primitive>;
}

interface SpanData {
  span: SpanContext;
}

type EnvelopeData = MessageData | ExceptionData | SpanData;
interface AnrData {
  blockedForMs: number;
  isInForeground?: boolean;
  lastBreadcrumb?: CoreBreadcrumb;
  threads?: Array<AnrThread>;
}

class DefaultTransport implements Transport {
  private options: OhosSentryOptions;
  private http: HttpTransportImpl | null = null;
  private sdk: SdkTransport | null = null;
  constructor(options: OhosSentryOptions) {
    this.options = options;
    // 优先使用官方 sentry SDK（若调用方已用 DSN 初始化）
    this.sdk = new SdkTransport(options);
    // 若提供 httpEndpoint 则启用 HTTP 传输
    if (options.httpEndpoint) {
      const httpOpts: HttpTransportOptions = {
        endpointUrl: options.httpEndpoint,
        headers: options.httpHeaders,
        connectTimeoutMs: options.httpConnectTimeoutMs,
        readTimeoutMs: options.httpReadTimeoutMs,
        maxRetries: options.httpMaxRetries,
        retryBaseDelayMs: options.httpRetryBaseDelayMs,
        debug: options.debug,
      };
      this.http = new HttpTransportImpl(httpOpts);
    }
  }
  async send(payload: Envelope): Promise<void> {
    // 若官方 SDK 可用，优先转发
    if (this.sdk) {
      const ok = await this.sdk.trySend(payload);
      if (ok) return;
    }
    // 否则退回 HTTP（若配置了 endpoint）或调试日志
    if (this.http) {
      await this.http.send(payload);
      return;
    }
    if (this.options.debug) {
      console.info('SentryOHOS send (debug mock):', 'type=' + payload.type);
    }
  }
}

class FunctionTransport implements Transport {
  private fn: (payload: Envelope) => Promise<void>;
  constructor(fn: (payload: Envelope) => Promise<void>) { this.fn = fn; }
  async send(payload: Envelope): Promise<void> { await this.fn(payload); }
}

class SdkTransport {
  private options: OhosSentryOptions;
  constructor(options: OhosSentryOptions) { this.options = options; }
  async trySend(env: Envelope): Promise<boolean> {
    try {
      if (env.type === 'message') {
        const d = env.data as MessageData;
        await Sentry.captureMessage(d.message);
        return true;
      } else if (env.type === 'exception') {
        const d = env.data as ExceptionData;
        const msg = d && d.message ? d.message : 'Error';
        await Sentry.captureException(new Error(msg));
        return true;
      } else if (env.type === 'span') {
        const d = env.data as SpanData;
        // 可换为官方性能 API；这里将 span 名称作为 message 上报
        const name = d && d.span ? d.span.name : 'span';
        await Sentry.captureMessage('span: ' + name);
        return true;
      }
    } catch (_) {
      // SDK 未初始化或调用失败，回退到其它通道
    }
    return false;
  }
}

export class SentryOhos {
  private static _initialized = false;
  private static _options: OhosSentryOptions = new SentryOhosOptions();
  private static _transport: Transport | null = null;
  private static _breadcrumbs: BreadcrumbStore | null = null;
  private static _session: SessionTracker | null = null;
  private static _appStart: AppStartMonitor | null = null;
  private static _anr: AnrMonitor | null = null;
  private static _isInForeground: boolean = true;
  private static _baseContext: common.BaseContext | undefined;
  private static _autoBc: AutoBreadcrumbs | null = null;
  private static _abilityBc: AbilityLifecycleBreadcrumbs | null = null;
  private static _freezeBreadcrumbsMaxKeys: number = 8;
  private static _appStartIso?: string;
  private static _frames?: FramesMonitor;
  private static _lastErrorEventId?: string;

  // 对外提供只读开关，供 HttpClient 等使用
  static isHttpBreadcrumbsEnabled(): boolean {
    return (SentryOhos._options.enableHttpBreadcrumbs === true);
  }
  static isHttpTracingEnabled(): boolean {
    return (SentryOhos._options.enableHttpTracing === true);
  }

  // 手动记录心跳（供外部调用，用于在阻塞前记录状态）
  static beatAnr(): void {
    try {
      if (SentryOhos._anr) {
        SentryOhos._anr.beatManual();
      }
    } catch (err) {
      console.error(`[Sentry] SentryOhos EXCEPTION: Failed to beat ANR: ${err}`);
    }
  }

  // 手动触发 ANR 检测（用于测试或外部触发）
  static triggerAnrCheck(): void {
    try {
      if (SentryOhos._anr) {
        SentryOhos._anr.check();
      }
    } catch (err) {
      console.error(`[Sentry] SentryOhos EXCEPTION: Failed to trigger ANR check: ${err}`);
    }
  }

  static init(options: SentryOhosOptionsInit | SentryOhosOptions): void {
    if (SentryOhos._initialized) {
      HarmonyLogger.warn('SentryOhos already initialized');
      return;
    }
    // 合并默认项
    const merged = SentryOhos.mergeOptions(options as SentryOhosOptionsInit);
    if (options && options.maxBreadcrumbs !== undefined) merged.maxBreadcrumbs = options.maxBreadcrumbs;
    if (options && options.anrThresholdMs !== undefined) merged.anrThresholdMs = options.anrThresholdMs;
    if (options && options.anrTickerIntervalMs !== undefined) merged.anrTickerIntervalMs = options.anrTickerIntervalMs;

    SentryOhos._options = merged;
    try { SentryOhos._appStartIso = new Date().toISOString(); } catch (_) {}
    SentryOhos._freezeBreadcrumbsMaxKeys = (merged.freezeBreadcrumbsMaxKeys as number) || 8;

    // 调用官方 sentry SDK 的初始化，类比 Android 端调用 Sentry.init
    try {
      const sopts = new SentryOptions();
      sopts.dsn = merged.dsn ? merged.dsn : '';
      sopts.debug = merged.debug === true;
      sopts.release = merged.release;
      sopts.environment = merged.environment;
      // 配置缓存目录（供 HttpTransport 使用），优先使用 BaseContext 提供的 filesDir/cacheDir
      try {
        interface FileDirProvider { filesDir?: string; cacheDir?: string }
        const base = SentryOhos._baseContext as FileDirProvider;
        const baseDir = (base && (base.filesDir || base.cacheDir)) ? (base.filesDir || base.cacheDir) as string : undefined;
        if (baseDir) {
          const cachePath = `${baseDir}/sentry-cache`;
          sopts.cacheDirPath = cachePath;
        }
      } catch (_) {}
      // 透传采样与回调、Tracing、Profiling 等（与 Android 对齐）
      if (merged.tracesSampleRate !== undefined) sopts.tracesSampleRate = merged.tracesSampleRate;
      if (merged.errorsSampleRate !== undefined) sopts.errorsSampleRate = merged.errorsSampleRate;
      if (merged.tracesSampler) sopts.tracesSampler = merged.tracesSampler;
      if (merged.enableTracing !== undefined) sopts.enableTracing = merged.enableTracing;
      if (merged.tracePropagationTargets) sopts.tracePropagationTargets = merged.tracePropagationTargets;
      if (merged.attachStacktrace !== undefined) sopts.attachStacktrace = merged.attachStacktrace;
      if (merged.enableAutoSessionTracking !== undefined) sopts.enableAutoSessionTracking = merged.enableAutoSessionTracking;
      if (merged.sessionTrackingIntervalMillis !== undefined) sopts.sessionTrackingIntervalMillis = merged.sessionTrackingIntervalMillis;
      if (merged.sendClientReports !== undefined) sopts.sendClientReports = merged.sendClientReports;
      if (merged.profilesSampleRate !== undefined) sopts.profilesSampleRate = merged.profilesSampleRate;
      if (merged.profilesSampler) sopts.profilesSampler = merged.profilesSampler;
      if (merged.beforeSendEvent) sopts.beforeSend = merged.beforeSendEvent;
      if (merged.beforeBreadcrumbCore) sopts.beforeBreadcrumb = merged.beforeBreadcrumbCore;
      if (merged.cacheDirPath) sopts.cacheDirPath = merged.cacheDirPath;
      // 如需自定义缓存目录、transportFactory，可在此扩展
      Sentry.init(sopts);
    } catch (_) {
      // 若官方 SDK 初始化异常，仍继续本地初始化，确保不阻断
    }

    SentryOhos._transport = merged.transport ? new FunctionTransport(merged.transport) : new DefaultTransport(SentryOhos._options);

    const cap = (SentryOhos._options.maxBreadcrumbs !== undefined) ? SentryOhos._options.maxBreadcrumbs : 50;
    SentryOhos._breadcrumbs = new BreadcrumbStore(cap);
    SentryOhos._session = new SessionTracker();
    SentryOhos._appStart = new AppStartMonitor();

    // 将静态上下文注入 Sentry Scope，确保所有事件（包括非 ANR）均携带
    try {
      const deviceCtx = collectDeviceContext();
      const appCtx = collectAppContext();
      const runtimeCtx = collectRuntimeContext();
      // Device 标准对象 + 扩展字段（合并到 scope）
      const devMerged: Record<string, Object> = {};
      if (typeof (deviceCtx['model']) === 'string') devMerged['model'] = deviceCtx['model'] as string;
      if (typeof (deviceCtx['brand']) === 'string') {
        const brandVal = deviceCtx['brand'] as string;
        devMerged['brand'] = brandVal;
        devMerged['manufacturer'] = brandVal;
      }
      if (typeof runtimeCtx.batteryLevel === 'number') devMerged['battery_level'] = runtimeCtx.batteryLevel as Object;
      if (typeof runtimeCtx.isCharging === 'boolean') devMerged['charging'] = runtimeCtx.isCharging as Object;
      if (runtimeCtx.networkType) {
        devMerged['connection_type'] = runtimeCtx.networkType as Object;
        devMerged['online'] = (runtimeCtx.networkType !== 'none') as Object;
      }
      if (typeof runtimeCtx.memoryTotalMb === 'number') devMerged['memory_size'] = Math.floor(runtimeCtx.memoryTotalMb * 1024 * 1024) as Object;
      if (typeof runtimeCtx.memoryUsedMb === 'number' && typeof runtimeCtx.memoryTotalMb === 'number') {
        const freeMb = runtimeCtx.memoryTotalMb - runtimeCtx.memoryUsedMb;
        if (freeMb >= 0) devMerged['free_memory'] = Math.floor(freeMb * 1024 * 1024) as Object;
      }
      const cpuCount = getProcessorCount();
      if (typeof cpuCount === 'number') devMerged['processor_count'] = cpuCount as Object;
      const ltz = getLocaleTimezone();
      if (ltz.locale) devMerged['locale'] = ltz.locale as Object;
      if (ltz.language) devMerged['language'] = ltz.language as Object;
      if (ltz.timezone) devMerged['timezone'] = ltz.timezone as Object;
      if (typeof (deviceCtx['archs']) === 'string') {
        const a = (deviceCtx['archs'] as string).split(',');
        devMerged['archs'] = a as Object;
      }
      if (typeof (deviceCtx['chipset']) === 'string') devMerged['chipset'] = deviceCtx['chipset'] as Object;
      Sentry.setContext('device', devMerged as Object);

      const osCtx: Record<string, Primitive> = {};
      osCtx['name'] = 'OpenHarmony';
      const kernel = getKernelVersion();
      if (kernel !== undefined) osCtx['kernelVersion'] = kernel;
      if (typeof (deviceCtx['osVersion']) === 'string') osCtx['version'] = deviceCtx['osVersion'] as string;
      if (typeof (deviceCtx['build']) === 'string') osCtx['build'] = deviceCtx['build'] as string;
      if (typeof (deviceCtx['softwareModel']) === 'string') osCtx['softwareModel'] = deviceCtx['softwareModel'] as string;
      if (typeof (deviceCtx['buildFeatures']) === 'string') osCtx['buildFeatures'] = deviceCtx['buildFeatures'] as string;
      // rooted 启发式
      const rootedMaybe = detectRooted();
      if (typeof rootedMaybe === 'boolean') osCtx['rooted'] = rootedMaybe;
      Sentry.setContext('os', osCtx as Object);

      const appOut: Record<string, Primitive> = {};
      if (appCtx['appName'] !== undefined) appOut['app_name'] = appCtx['appName'] as string;
      if (appCtx['packageName'] !== undefined) appOut['app_identifier'] = appCtx['packageName'] as string;
      if (appCtx['appVersion'] !== undefined) appOut['app_version'] = appCtx['appVersion'] as string;
      if (appCtx['appBuild'] !== undefined) appOut['app_build'] = appCtx['appBuild'] as string;
      appOut['in_foreground'] = SentryOhos._isInForeground;
      if (typeof (appCtx['permissionsCsv']) === 'string') {
        const p = (appCtx['permissionsCsv'] as string).split(',');
        (appOut as Record<string, Object>)['permissions'] = p as Object;
      }
      if (SentryOhos._appStartIso) {
        appOut['app_start_time'] = SentryOhos._appStartIso as string;
        appOut['start_time'] = SentryOhos._appStartIso as string;
      }
      // 注入 APP 内存（bytes），更贴近 Android JSON 展示
      try {
        if (typeof runtimeCtx.memoryUsedMb === 'number') {
          const mb = runtimeCtx.memoryUsedMb as number;
          (appOut as Record<string, Object>)['app_memory'] = Math.floor(mb * 1024 * 1024) as Object;
        }
      } catch (_) {}
      Sentry.setContext('app', appOut as Object);

      const runtimeObj: RuntimeContextOut = {} as RuntimeContextOut;
      if (runtimeCtx.networkType !== undefined) runtimeObj.networkType = runtimeCtx.networkType;
      if (runtimeCtx.batteryLevel !== undefined) runtimeObj.batteryLevel = runtimeCtx.batteryLevel;
      if (runtimeCtx.isCharging !== undefined) runtimeObj.isCharging = runtimeCtx.isCharging;
      if (runtimeCtx.memoryUsedMb !== undefined) runtimeObj.memoryUsedMb = runtimeCtx.memoryUsedMb;
      if (runtimeCtx.memoryTotalMb !== undefined) runtimeObj.memoryTotalMb = runtimeCtx.memoryTotalMb;
      if (runtimeCtx.foregroundPage !== undefined) runtimeObj.foregroundPage = runtimeCtx.foregroundPage;
      if (runtimeCtx.bootTime !== undefined) runtimeObj.bootTime = runtimeCtx.bootTime;
      if (runtimeCtx.arch !== undefined) runtimeObj.arch = runtimeCtx.arch;
      if (runtimeCtx.cpuFrequencyMHz !== undefined) runtimeObj.cpuFrequencyMHz = runtimeCtx.cpuFrequencyMHz;
      Sentry.setContext('runtime', (runtimeObj as Object));
      // Dart/Flutter 运行时与 flutter_context（展示卡片所需字段）
      try {
        const dartCtx: Record<string, Primitive> = {};
        dartCtx['type'] = 'runtime';
        dartCtx['name'] = 'Dart';
        dartCtx['runtime'] = 'Dart VM';
        // 版本与原始描述若上层未提供，输出简单占位，避免空卡片
        dartCtx['version'] = 'unknown';
        dartCtx['raw_description'] = 'Dart on OpenHarmony';
        Sentry.setContext('dart', dartCtx as Object);

        const flutterRt: Record<string, Primitive> = {};
        flutterRt['type'] = 'runtime';
        flutterRt['name'] = 'Flutter';
        flutterRt['compiler'] = 'Dart VM';
        Sentry.setContext('flutter', flutterRt as Object);

        const flutterCtx: Record<string, Primitive> = {};
        flutterCtx['type'] = 'flutter_context';
        flutterCtx['current_lifecycle_state'] = (SentryOhos._isInForeground ? 'resumed' : 'paused');
        flutterCtx['default_route_name'] = '/';
        flutterCtx['has_render_view'] = true;
        flutterCtx['initial_lifecycle_state'] = 'AppLifecycleState.resumed';
        Sentry.setContext('flutter_context', flutterCtx as Object);
      } catch (_) {}

      // 默认 tags
      Sentry.setTag('event.origin', 'openharmony');
      Sentry.setTag('event.environment', 'arkts');
      if (typeof runtimeCtx.lowMemory === 'boolean') Sentry.setTag('low_memory', String(runtimeCtx.lowMemory));
      Sentry.setTag('is_foreground', String(SentryOhos._isInForeground));
    } catch (_) {}
    const enableAnr = (SentryOhos._options.enableAnr !== undefined) ? (SentryOhos._options.enableAnr as boolean) : true;
    // 检查是否在debug模式下允许ANR检测（默认false，需要显式开启）
    const debugMode = (SentryOhos._options.debug === true);
    const anrReportInDebug = (SentryOhos._options.anrReportInDebug === true);
    const shouldEnableAnr = enableAnr && (!debugMode || anrReportInDebug);
    if (shouldEnableAnr) {
      const anrMs = (SentryOhos._options.anrThresholdMs !== undefined) ? SentryOhos._options.anrThresholdMs : 5000;
      // 使用正常间隔（默认5000ms），不再强制1000ms以避免主线程卡顿
      // 主要依赖系统级别的hiAppEvent Watcher来检测ANR，ticker仅作为辅助检测
      const anrTick = (SentryOhos._options.anrTickerIntervalMs !== undefined) ? SentryOhos._options.anrTickerIntervalMs : 5000;
      SentryOhos._anr = new AnrMonitor(anrMs, async (e) => {
        // 双重检查：如果在debug模式且不允许上报，则跳过
        const currentDebug = (SentryOhos._options.debug === true);
        const currentAnrReportInDebug = (SentryOhos._options.anrReportInDebug === true);
        if (currentDebug && !currentAnrReportInDebug) {
          return;
        }
        try {
      // 取最后一条面包屑
      let crumbsCore: Array<CoreBreadcrumb> = [];
      let crumbs: Array<SdkBreadcrumb> = [];
      try {
        crumbsCore = SentryOhos._breadcrumbs ? SentryOhos._breadcrumbs.snapshot() : [];
        crumbs = [];
        for (let i = 0; i < crumbsCore.length; i++) {
          const c = crumbsCore[i] as CoreBreadcrumb;
          const sc = toSdkBreadcrumb(c);
          crumbs.push(sc);
        }
      } catch (err) {
        console.error(`[Sentry] SentryOhos ERROR in breadcrumbs collection: ${err}`);
        // 确保变量已初始化
        crumbsCore = [];
        crumbs = [];
      }
      // 构建接近 Android 的 SentryEvent，使用机制 ANR
      let event: SentryEvent | null = null;
      try {
        event = new SentryEvent('Application Not Responding');
        // 与 Android 对齐：fatal + 指纹包含 foreground-anr
        event.level = SentryLevel.Fatal;
        const fp: Array<string> = [];
        fp.push('{{ default }}');
        if (SentryOhos._isInForeground) fp.push('foreground-anr');
        else fp.push('background-anr');
        event.fingerprint = fp;
      } catch (err) {
        console.error(`[Sentry] SentryOhos ERROR in SentryEvent creation: ${err}`);
        return; // 无法创建事件，直接返回
      }
      if (!event) {
        console.error(`[Sentry] SentryOhos FATAL: event is null after creation`);
        return;
      }
    // tags、contexts
      event.tags['is_foreground'] = String(SentryOhos._isInForeground);
      event.tags['event.origin'] = 'openharmony';
      event.tags['event.environment'] = 'arkts';
      const deviceCtx = collectDeviceContext();
      const appCtx = collectAppContext();
      const runtimeCtx = collectRuntimeContext();
      // ✅ 先合并所有 collectDeviceContext 中的字段到 device
      const devObj: Record<string, Primitive> = {};
      const deviceKeys = Object.keys(deviceCtx);
      for (let i = 0; i < deviceKeys.length; i++) {
        const key = deviceKeys[i];
        if (deviceCtx[key] !== undefined) {
          devObj[key] = deviceCtx[key];
        }
      }

      // 对齐 Android：contexts.device 使用标准 Device 对象
      const dev = new Device();
      // 基础设备信息
      if (typeof (deviceCtx['model']) === 'string') dev.model = deviceCtx['model'] as string;
      if (typeof (deviceCtx['family']) === 'string') dev.family = deviceCtx['family'] as string;
      if (typeof (deviceCtx['modelId']) === 'string') dev.modelId = deviceCtx['modelId'] as string;
      if (typeof (deviceCtx['id']) === 'string') dev.id = deviceCtx['id'] as string;
      // name：优先使用 model，回退到 deviceCtx 中的 name
      if (typeof (deviceCtx['model']) === 'string') {
        dev.name = deviceCtx['model'] as string;
      } else if (typeof (deviceCtx['name']) === 'string') {
        dev.name = deviceCtx['name'] as string;
      }
      if (typeof (deviceCtx['brand']) === 'string') {
        const brandVal = deviceCtx['brand'] as string;
        dev.brand = brandVal;
        dev.manufacturer = brandVal;
      }
      if (typeof (deviceCtx['manufacturer']) === 'string') dev.manufacturer = deviceCtx['manufacturer'] as string;
      // 电池信息
      if (typeof runtimeCtx.batteryLevel === 'number') dev.batteryLevel = runtimeCtx.batteryLevel;
      if (typeof runtimeCtx.isCharging === 'boolean') dev.isCharging = runtimeCtx.isCharging;
      // 电池温度：从 deviceCtx 或 runtimeCtx 获取
      if (typeof (deviceCtx['battery_temperature']) === 'number') {
        dev.batteryTemperature = deviceCtx['battery_temperature'] as number;
      }
      // online/connectionType 推断
      if (runtimeCtx.networkType) {
        dev.connectionType = runtimeCtx.networkType;
        dev.isOnline = runtimeCtx.networkType !== 'none';
      }
      // 内存：memorySize/freeMemory（转换为字节，完全对齐 Android 序列化习惯）
      if (typeof runtimeCtx.memoryTotalMb === 'number') dev.memorySize = Math.floor(runtimeCtx.memoryTotalMb * 1024 * 1024);
      if (typeof runtimeCtx.memoryUsedMb === 'number' && typeof runtimeCtx.memoryTotalMb === 'number') {
        const freeMb = runtimeCtx.memoryTotalMb - runtimeCtx.memoryUsedMb;
        if (freeMb >= 0) dev.freeMemory = Math.floor(freeMb * 1024 * 1024);
      }
      // 处理器信息
      const cpuCount = getProcessorCount();
      if (typeof cpuCount === 'number') dev.processorCount = cpuCount;
      // 处理器频率：优先从 runtimeCtx，回退到 deviceCtx
      if (typeof runtimeCtx.cpuFrequencyMHz === 'number') {
        dev.processorFrequency = runtimeCtx.cpuFrequencyMHz;
      } else if (typeof (deviceCtx['processor_frequency']) === 'number') {
        dev.processorFrequency = deviceCtx['processor_frequency'] as number;
      }
      // 屏幕信息
      if (typeof runtimeCtx.screenDpi === 'number') dev.screenDpi = runtimeCtx.screenDpi;
      if (typeof runtimeCtx.screenDensity === 'number') dev.screenDensity = runtimeCtx.screenDensity;
      // 计算 screenResolution 字符串（对齐 Android 格式）
      if (typeof runtimeCtx.screenWidthPx === 'number' && typeof runtimeCtx.screenHeightPx === 'number') {
        dev.screenResolution = `${runtimeCtx.screenWidthPx}x${runtimeCtx.screenHeightPx}`;
      }
      // simulator
      if (typeof (deviceCtx['simulator']) === 'boolean') dev.simulator = deviceCtx['simulator'] as boolean;
      // 语言/时区/locale
      const ltz = getLocaleTimezone();
      if (ltz.locale) dev.locale = ltz.locale;
      if (ltz.language) dev.language = ltz.language;
      if (ltz.timezone) dev.timezone = ltz.timezone;

      // ✅ 将 dev 对象的所有属性合并到 devObj
      const devKeys = Object.keys(dev);
      for (let i = 0; i < devKeys.length; i++) {
        const key = devKeys[i];
        const value = (dev as Record<string, Primitive>)[key];
        if (value !== undefined) {
          devObj[key] = value;
        }
      }

      // ✅ 添加 Android 对齐的额外字段
      // archs：作为数组（Android 端显示为数组格式）
      if (typeof (deviceCtx['archs']) === 'string') {
        const archsStr = deviceCtx['archs'] as string;
        const archsArr = archsStr.split(',').map(s => s.trim()).filter(s => s.length > 0);
        if (archsArr.length > 0) {
          (devObj as Record<string, Object>)['archs'] = archsArr as Object;
        }
      }
      // 屏幕像素值（Android 端单独显示这些字段，使用 snake_case 以对齐序列化逻辑）
      if (typeof runtimeCtx.screenWidthPx === 'number') {
        devObj['screen_width_pixels'] = runtimeCtx.screenWidthPx;
      }
      if (typeof runtimeCtx.screenHeightPx === 'number') {
        devObj['screen_height_pixels'] = runtimeCtx.screenHeightPx;
      }

      // ✅ 使用合并后的完整对象
      event.contexts['device'] = devObj as Object;
      const osCtx: Record<string, Primitive> = {};
      osCtx['name'] = 'OpenHarmony';
      const kernel = getKernelVersion();
      if (kernel !== undefined) osCtx['kernelVersion'] = kernel;
      if (typeof (deviceCtx['osVersion']) === 'string') osCtx['version'] = deviceCtx['osVersion'] as string;
      if (typeof (deviceCtx['build']) === 'string') osCtx['build'] = deviceCtx['build'] as string;
      if (typeof (deviceCtx['softwareModel']) === 'string') osCtx['softwareModel'] = deviceCtx['softwareModel'] as string;
      if (typeof (deviceCtx['buildFeatures']) === 'string') osCtx['buildFeatures'] = deviceCtx['buildFeatures'] as string;
      event.contexts['os'] = osCtx as Object;
      // app: 对齐 Android 常用字段
      const appOut: Record<string, Primitive> = {};
      if (appCtx['appName'] !== undefined) appOut['app_name'] = appCtx['appName'] as string;
      if (appCtx['packageName'] !== undefined) appOut['app_identifier'] = appCtx['packageName'] as string;
      if (appCtx['appVersion'] !== undefined) appOut['app_version'] = appCtx['appVersion'] as string;
      if (appCtx['appBuild'] !== undefined) appOut['app_build'] = appCtx['appBuild'] as string;
      appOut['in_foreground'] = SentryOhos._isInForeground;
      if (typeof (appCtx['permissionsCsv']) === 'string') {
        const arr = (appCtx['permissionsCsv'] as string).split(',');
        (appOut as Record<string, Object>)['permissions'] = arr as Object;
      }
      event.contexts['app'] = appOut as Object;
      // 显式对象：避免未声明类型的字面量
      const runtimeObj: Record<string, Primitive> = {};
      if (runtimeCtx.networkType !== undefined) runtimeObj['networkType'] = runtimeCtx.networkType;
      if (runtimeCtx.batteryLevel !== undefined) runtimeObj['batteryLevel'] = runtimeCtx.batteryLevel;
      if (runtimeCtx.isCharging !== undefined) runtimeObj['isCharging'] = runtimeCtx.isCharging;
      if (runtimeCtx.memoryUsedMb !== undefined) runtimeObj['memoryUsedMb'] = runtimeCtx.memoryUsedMb;
      if (runtimeCtx.memoryTotalMb !== undefined) runtimeObj['memoryTotalMb'] = runtimeCtx.memoryTotalMb;
      if (runtimeCtx.freeMemoryMb !== undefined) runtimeObj['freeMemoryMb'] = runtimeCtx.freeMemoryMb;
      if (runtimeCtx.foregroundPage !== undefined) runtimeObj['foregroundPage'] = runtimeCtx.foregroundPage;
      if (runtimeCtx.online !== undefined) runtimeObj['online'] = runtimeCtx.online;
      if (runtimeCtx.arch !== undefined) runtimeObj['arch'] = runtimeCtx.arch;
      if (runtimeCtx.cpuFrequencyMHz !== undefined) runtimeObj['cpuFrequencyMHz'] = runtimeCtx.cpuFrequencyMHz;
      if (runtimeCtx.screenDpi !== undefined) runtimeObj['screenDpi'] = runtimeCtx.screenDpi;
      if (runtimeCtx.screenDensity !== undefined) runtimeObj['screenDensity'] = runtimeCtx.screenDensity;
      if (runtimeCtx.screenWidthPx !== undefined) runtimeObj['screenWidthPx'] = runtimeCtx.screenWidthPx;
      if (runtimeCtx.screenHeightPx !== undefined) runtimeObj['screenHeightPx'] = runtimeCtx.screenHeightPx;
      if (runtimeCtx.storageTotalGb !== undefined) runtimeObj['storageTotalGb'] = runtimeCtx.storageTotalGb;
      if (runtimeCtx.storageFreeGb !== undefined) runtimeObj['storageFreeGb'] = runtimeCtx.storageFreeGb;
      // contexts 的值类型定义为 Object，这里直接赋值为 Record<string, Primitive>
      // ArkTS 需要显式类型，无需使用 unknown/any
      (event.contexts as Record<string, Object>)['runtime'] = runtimeObj as Object;
      // 低内存 tag
      if (typeof runtimeCtx.lowMemory === 'boolean') {
        event.tags.low_memory = String(runtimeCtx.lowMemory);
      }
      event.breadcrumbs = crumbs;
      // 线程占位
      // 可扩展：采集真实栈
      // 异常机制：与 Android 对齐
      const mech = new Mechanism();
      mech.type = 'AppExitInfo';
      mech.handled = false;
      const ex = new SentryException();
      ex.type = 'ApplicationNotResponding';
      ex.value = 'ANR';
      ex.mechanism = mech;
      event.exceptions = [ex];
      event.extras['blockedForMs'] = String(e.blockedForMs);
      // 线程快照占位：主线程（贴近 Android）
      try {
        const th = new SentryThread();
        th.id = 1;
        th.name = 'main';
        th.current = true;
        th.crashed = true;
        th.main = true;
        th.state = 'Blocked';
        // 简化的栈帧（从底到顶，贴近 Android 展示顺序：最顶为 main）
        const frames: Array<SentryStackFrame> = [];
        const f1 = new SentryStackFrame(); f1.function = 'android.os.Looper.loop'; f1.module = 'android.os.Looper'; f1.in_app = false; frames.push(f1);
        const f2 = new SentryStackFrame(); f2.function = 'android.app.ActivityThread.main'; f2.module = 'android.app.ActivityThread'; f2.in_app = false; frames.push(f2);
        const f3 = new SentryStackFrame(); f3.function = 'java.lang.reflect.Method.invoke'; f3.module = 'java.lang.reflect.Method'; f3.in_app = false; frames.push(f3);
        const f4 = new SentryStackFrame(); f4.function = 'com.android.internal.os.RuntimeInit$MethodAndArgsCaller.run'; f4.module = 'com.android.internal.os.RuntimeInit$MethodAndArgsCaller'; f4.in_app = false; frames.push(f4);
        const f5 = new SentryStackFrame(); f5.function = 'com.android.internal.os.ZygoteInit.main'; f5.module = 'com.android.internal.os.ZygoteInit'; f5.in_app = false; frames.push(f5);
        // 顶部应用层（与触发阻塞的入口保持一致，便于识别）
        const fTop = new SentryStackFrame(); fTop.function = 'io.sentry.ohos.ANR'; fTop.module = 'app.main'; fTop.in_app = true; frames.unshift(fTop);
        const st = new SentryStackTrace(frames);
        th.stacktrace = st;
        event.threads = [th];
      } catch (_) {}
      // 调用官方 SDK 的 captureEvent 分层，并注入 replay_id（若有）
      try {
        const rid = getReplayId();
        const enabled = (SentryOhos._options.enableReplay === true);
        if (enabled && typeof rid === 'string' && rid.length > 0) {
          class ReplayContext { replay_id?: string; id?: string; type?: string; constructor(id: string) { this.replay_id = id; this.id = id; this.type = 'replay'; } }
          (event.contexts as Record<string, Object>)['replay'] = new ReplayContext(rid) as Object;
          event.tags['replayId'] = rid;
          try { Sentry.setTag('replayId', rid); } catch (_) {}
        }
      } catch (err) {
        console.error(`[Sentry] SentryOhos ERROR in replay configuration: ${err}`);
      }
      // 主要路径：通过 Sentry.captureEvent 发送（会经过缓存机制，失败时自动缓存）
      // 重要：先立即同步保存到缓存，然后再尝试发送（因为应用可能在发送过程中崩溃）
      try {
        try {
          const hub = Sentry.getHub();
          interface HubWithCache { cache: FileEnvelopeCache | null }
          const hubWithCache = hub as HubWithCache;
          if (hub && hubWithCache.cache) {
            const cache = hubWithCache.cache;
            try {
              cache.store(event);
            } catch (cacheErr) {
              console.error(`[Sentry] SentryOhos failed to cache event: ${cacheErr}`);
            }
          }
        } catch (hubErr) {
          console.error(`[Sentry] SentryOhos failed to get hub/cache: ${hubErr}`);
        }
        // 不等待发送完成，因为应用可能崩溃
        Sentry.captureEvent(event).catch((err: Error | Object) => {
          console.error(`[Sentry] SentryOhos captureEvent promise rejected: ${err}`);
        });
      } catch (err) {
        console.error(`[Sentry] SentryOhos ERROR in captureEvent setup: ${err}`);
        if (err instanceof Error) {
          console.error(`[Sentry] SentryOhos ERROR details: ${err.message}`);
          if (err.stack) console.error(`[Sentry] SentryOhos ERROR stack: ${err.stack}`);
        }
      }
      // 备用路径：同时通过 InternalSentrySdk.captureCoreEnvelope 发送（直接发送，失败不缓存）
      try {
        const mainThread: AnrThread = { name: 'main', state: 'blocked' };
        const data: AnrData = {
          blockedForMs: e.blockedForMs,
          isInForeground: SentryOhos._isInForeground,
          lastBreadcrumb: crumbsCore.length > 0 ? crumbsCore[crumbsCore.length - 1] : undefined,
          threads: [ mainThread ],
        };
        const envelope = SentryOhos.buildEnvelope('anr', data);
        await InternalSentrySdk.captureCoreEnvelope(envelope);
      } catch (err) {
        console.error(`[Sentry] SentryOhos ERROR in captureCoreEnvelope: ${err}`);
        if (err instanceof Error) {
          console.error(`[Sentry] SentryOhos ERROR details: ${err.message}`);
          if (err.stack) console.error(`[Sentry] SentryOhos ERROR stack: ${err.stack}`);
        }
      }
        } catch (outerErr) {
          // 捕获整个回调中未处理的异常
          console.error(`[Sentry] SentryOhos FATAL: Unhandled error in ANR callback: ${outerErr}`);
          if (outerErr instanceof Error) {
            console.error(`[Sentry] SentryOhos FATAL: Error message: ${outerErr.message}`);
            if (outerErr.stack) console.error(`[Sentry] SentryOhos FATAL: Error stack: ${outerErr.stack}`);
          }
        }
      });
      // 启动主线程漂移检测
      try {
        if (SentryOhos._anr) {
          SentryOhos._anr.startTicker(anrTick);
        } else {
          console.error(`[Sentry] SentryOhos ERROR: _anr is null, cannot start ticker`);
        }
      } catch (err) {
        try {
          console.error(`[Sentry] SentryOhos failed to start ANR ticker: ${JSON.stringify(err)}`);
        } catch (_) {}
      }
    }

    // 启动自动面包屑
    try {
      if (SentryOhos._breadcrumbs) {
        SentryOhos._autoBc = new AutoBreadcrumbs(SentryOhos._breadcrumbs);
        SentryOhos._autoBc.start();
      }
    } catch (_) {}

    // 帧率监控（FramesTracking）：写面包屑 + 聚合到 measurements
    try {
      const enableFrames = (SentryOhos._options.enableFramesTracking !== undefined) ? (SentryOhos._options.enableFramesTracking as boolean) : true;
      if (enableFrames && SentryOhos._breadcrumbs) {
        const slowMs = (SentryOhos._options.slowFrameThresholdMs as number) || 48;
        const frozenMs = (SentryOhos._options.frozenFrameThresholdMs as number) || 700;
        const sample = (SentryOhos._options.framesSampleRate as number) || 1.0;
        SentryOhos._frames = new FramesMonitor({ slowFrameThresholdMs: slowMs, frozenFrameThresholdMs: frozenMs, sampleRate: sample }, (b) => {
          SentryOhos.addBreadcrumb(b);
          // 同步到 TraceManager measurements（如存在活动事务）
          try {
            const tm = TraceManager.get();
            if (tm.hasActive()) {
              const isFrozen = b && b.data && (b.data['frame_kind'] === 'frozen');
              const isSlow = b && b.data && (b.data['frame_kind'] === 'slow');
              if (isFrozen) tm.addMeasurement('frames_frozen', 1, 'item');
              if (isSlow) tm.addMeasurement('frames_slow', 1, 'item');
              tm.addMeasurement('frames_total', 1, 'item');
            }
          } catch (_) {}
        });
        SentryOhos._frames.start();
      }
    } catch (_) {}

    // 注册 Ability 生命周期面包屑（Application 级）
    try {
      const enableLifecycleBc = (SentryOhos._options.enableAppLifecycleBreadcrumbs !== undefined) ? (SentryOhos._options.enableAppLifecycleBreadcrumbs as boolean) : true;
      if (enableLifecycleBc && SentryOhos._breadcrumbs && SentryOhos._baseContext) {
        // BaseContext -> ApplicationContext
        interface AppCtxProvidable { getApplicationContext?: () => object }
        const appProv = SentryOhos._baseContext as AppCtxProvidable;
        const appCtx = typeof appProv.getApplicationContext === 'function' ? appProv.getApplicationContext() : undefined;
        if (appCtx) {
          SentryOhos._abilityBc = new AbilityLifecycleBreadcrumbs(SentryOhos._breadcrumbs);
          const enableTracing = (SentryOhos._options.enableActivityLifecycleTracing !== undefined) ? (SentryOhos._options.enableActivityLifecycleTracing as boolean) : true;
          const tracingTimeout = (SentryOhos._options.lifecycleTracingTimeoutMs as number) || 10000;
          SentryOhos._abilityBc.install(appCtx, enableTracing, tracingTimeout);
        }
      }
    } catch (_) {}

    installGlobalErrorHandler((error: Error) => {
      SentryOhos.captureException(error).then(() => {
        try {
          if (SentryOhos._options.enableReplay && SentryOhos._options.replayServerUrl && SentryOhos._baseContext) {
            const replayEventId = SentryOhos._lastErrorEventId;
            captureReplayOnErrorApi(SentryOhos._baseContext, replayEventId).then(() => {
              uploadReplayApi(SentryOhos._options.replayServerUrl as string, SentryOhos._baseContext as common.BaseContext).then(() => {}).catch(() => {});
            }).catch(() => {});
          }
        } catch (_) {}
      }).catch(() => {});
      if (SentryOhos._session) SentryOhos._session.error();
    });

    SentryOhos._initialized = true;
    if (SentryOhos._options.debug) console.info('SentryOhos initialized');
    // 启动时尝试发送缓存（若 SDK/缓存已启用）
    try {
      Sentry.flush(3000).catch((err: Error | string | Object) => {
        let errMsg: string = '';
        try {
          if (err instanceof Error) {
            errMsg = err.message;
          } else if (err && typeof err === 'object') {
            const errObj = err as Record<string, string>;
            errMsg = errObj.message || String(err);
          } else {
            errMsg = String(err);
          }
        } catch (_) {
          errMsg = String(err);
        }
        console.error(`[Sentry] SentryOhos flush error: ${errMsg}`);
      });
    } catch (err) {
      const errMsg = err instanceof Error ? (err as Error).message : String(err);
      console.error(`[Sentry] SentryOhos failed to initiate flush: ${errMsg}`);
    }

    // 启动回放：开启像素视频；500ms 一帧与 5s 一段；采样率 1.0/1.0 便于触发
    try {
      if (SentryOhos._options.enableReplay && SentryOhos._options.replayServerUrl && SentryOhos._baseContext) {
        startReplay({ context: SentryOhos._baseContext, serverUrl: SentryOhos._options.replayServerUrl, frameIntervalMs: 500, segmentMs: 5000, maskAllImages: true, enableScreenFrames: true, sessionSampleRate: 0.1, onErrorSampleRate: 1.0 });
      }
    } catch (_) {}
    // 安装 HiAppEvent Watcher（APP_CRASH 补采）
    try { if (merged.enableHiAppWatcher) SentryOhos.installHiAppWatcher(); } catch (_) {}

    // 安装用户交互集成（UI 点击、Ability 生命周期面包屑）
    try {
      if (merged.enableUserInteractionIntegration) {
        UserInteractionIntegration.install({
          enableUiBreadcrumbs: merged.enableUiBreadcrumbs,
          enableAppLifecycleBreadcrumbs: merged.enableAppLifecycleBreadcrumbs,
        });
      }
    } catch (_) {}
  }

  // 测试/兜底：在阻塞前预先生成并缓存 ANR 事件，避免阻塞期间被系统杀死导致回调无法执行
  static forceAnrEvent(blockedForMs: number): void {
    try {
      // 构建与 ANR 回调一致的事件结构
      const crumbsCore = SentryOhos._breadcrumbs ? SentryOhos._breadcrumbs.snapshot() : [];
      const crumbs: Array<SdkBreadcrumb> = [];
      for (let i = 0; i < crumbsCore.length; i++) crumbs.push(toSdkBreadcrumb(crumbsCore[i]));

      const event = new SentryEvent('Application Not Responding');
      event.level = SentryLevel.Fatal;
      const fp: Array<string> = [];
      fp.push('{{ default }}');
      fp.push(SentryOhos._isInForeground ? 'foreground-anr' : 'background-anr');
      event.fingerprint = fp;
      // 异常机制对齐 Android
      const mech = new Mechanism(); mech.type = 'AppExitInfo'; mech.handled = false;
      const ex = new SentryException(); ex.type = 'ApplicationNotResponding'; ex.value = 'ANR'; ex.mechanism = mech;
      event.exceptions = [ex];
      event.extras['blockedForMs'] = String(blockedForMs);
      // 线程快照占位
      try {
        const th = new SentryThread(); th.id = 1; th.name = 'main'; th.current = true; th.crashed = true; th.main = true; th.state = 'Blocked';
        const frames: Array<SentryStackFrame> = [];
        const f1 = new SentryStackFrame(); f1.function = 'android.os.Looper.loop'; f1.module = 'android.os.Looper'; f1.in_app = false; frames.push(f1);
        const f2 = new SentryStackFrame(); f2.function = 'android.app.ActivityThread.main'; f2.module = 'android.app.ActivityThread'; f2.in_app = false; frames.push(f2);
        const f3 = new SentryStackFrame(); f3.function = 'java.lang.reflect.Method.invoke'; f3.module = 'java.lang.reflect.Method'; f3.in_app = false; frames.push(f3);
        const f4 = new SentryStackFrame(); f4.function = 'com.android.internal.os.RuntimeInit$MethodAndArgsCaller.run'; f4.module = 'com.android.internal.os.RuntimeInit$MethodAndArgsCaller'; f4.in_app = false; frames.push(f4);
        const f5 = new SentryStackFrame(); f5.function = 'com.android.internal.os.ZygoteInit.main'; f5.module = 'com.android.internal.os.ZygoteInit'; f5.in_app = false; frames.push(f5);
        const fTop = new SentryStackFrame(); fTop.function = 'io.sentry.ohos.ANR'; fTop.module = 'app.main'; fTop.in_app = true; frames.unshift(fTop);
        const st = new SentryStackTrace(frames); th.stacktrace = st; event.threads = [th];
      } catch (_) {}

      // 注入 contexts（device/os/app/runtime）与 tags（与正常路径一致）
      try {
        const deviceCtx = collectDeviceContext(); const appCtx = collectAppContext(); const runtimeCtx = collectRuntimeContext();
        const devObj: Record<string, Primitive> = {}; const deviceKeys = Object.keys(deviceCtx);
        for (let i = 0; i < deviceKeys.length; i++) { const k = deviceKeys[i]; if (deviceCtx[k] !== undefined) devObj[k] = deviceCtx[k]; }
        (event.contexts as Record<string, Object>)['device'] = devObj as Object;
        const osCtx: Record<string, Primitive> = {}; osCtx['name'] = 'OpenHarmony';
        if (typeof (deviceCtx['osVersion']) === 'string') osCtx['version'] = deviceCtx['osVersion'] as string;
        (event.contexts as Record<string, Object>)['os'] = osCtx as Object;
        const appOut: Record<string, Primitive> = {}; if (appCtx['appName'] !== undefined) appOut['app_name'] = appCtx['appName'] as string; appOut['in_foreground'] = SentryOhos._isInForeground;
        (event.contexts as Record<string, Object>)['app'] = appOut as Object;
        const rt: Record<string, Primitive> = {}; if (runtimeCtx.networkType !== undefined) rt['networkType'] = runtimeCtx.networkType; (event.contexts as Record<string, Object>)['runtime'] = rt as Object;
        event.tags['is_foreground'] = String(SentryOhos._isInForeground);
      } catch (_) {}
      event.breadcrumbs = crumbs;

      // 先同步缓存，再尝试发送（缓存失败不影响发送）
      try {
        const hub = Sentry.getHub();
        interface HubWithCache { cache: FileEnvelopeCache | null }
        const h = hub as HubWithCache;
        if (h && h.cache) {
          try {
            h.cache.store(event);
          } catch (cacheErr) {
            // 缓存失败不影响事件发送（事件会通过HTTP发送，失败时 transport 层会自动缓存）
          }
        }
      } catch (e) {
        // 缓存访问错误，非关键
      }
      // 通过 Sentry.captureEvent 发送（如果发送失败，transport 层会自动缓存）
      try {
        Sentry.captureEvent(event).catch((err: Error) => {
          console.error(`[Sentry] SentryOhos forceAnrEvent captureEvent failed: ${err}`);
        });
      } catch (e) {
        console.error(`[Sentry] SentryOhos forceAnrEvent captureEvent sync error: ${e}`);
      }
      // 直接补发一个简易 anr core envelope，辅助服务端识别
      try {
        const mainThread: AnrThread = { name: 'main', state: 'blocked' };
        const data: AnrData = { blockedForMs: blockedForMs, isInForeground: SentryOhos._isInForeground, lastBreadcrumb: crumbsCore.length > 0 ? crumbsCore[crumbsCore.length - 1] : undefined, threads: [mainThread] };
        const env = SentryOhos.buildEnvelope('anr', data);
        InternalSentrySdk.captureCoreEnvelope(env);
      } catch (_) {}
    } catch (err) {
      console.error(`[Sentry] SentryOhos forceAnrEvent failed: ${err}`);
    }
  }


  private static mergeOptions(options: SentryOhosOptionsInit): OhosSentryOptions {
    const out: OhosSentryOptions = new SentryOhosOptions();
    if (typeof options.debug === 'boolean') out.debug = options.debug;
    if (typeof options.maxBreadcrumbs === 'number') out.maxBreadcrumbs = options.maxBreadcrumbs;
    if (typeof options.anrThresholdMs === 'number') out.anrThresholdMs = options.anrThresholdMs;
    if (typeof options.anrTickerIntervalMs === 'number') out.anrTickerIntervalMs = options.anrTickerIntervalMs;
    if (typeof options.enableAnr === 'boolean') out.enableAnr = options.enableAnr;
    if (typeof options.anrReportInDebug === 'boolean') out.anrReportInDebug = options.anrReportInDebug;
    out.dsn = (typeof options.dsn === 'string') ? options.dsn : '';
    if (typeof options.release === 'string') out.release = options.release;
    if (typeof options.environment === 'string') out.environment = options.environment;
    if (typeof options.dist === 'string') out.dist = options.dist;
    // 事件级 beforeSend 在 sentry/SentryOptions 中配置，这里不再承载
    if (typeof options.transport === 'function') out.transport = options.transport;
    if (typeof options.cacheDirPath === 'string') out.cacheDirPath = options.cacheDirPath;
    if (typeof options.httpEndpoint === 'string') out.httpEndpoint = options.httpEndpoint;
    if (options.httpHeaders) out.httpHeaders = options.httpHeaders;
    if (typeof options.httpConnectTimeoutMs === 'number') out.httpConnectTimeoutMs = options.httpConnectTimeoutMs;
    if (typeof options.httpReadTimeoutMs === 'number') out.httpReadTimeoutMs = options.httpReadTimeoutMs;
    if (typeof options.httpMaxRetries === 'number') out.httpMaxRetries = options.httpMaxRetries;
    if (typeof options.httpRetryBaseDelayMs === 'number') out.httpRetryBaseDelayMs = options.httpRetryBaseDelayMs;
    if (typeof options.tracesSampleRate === 'number') out.tracesSampleRate = options.tracesSampleRate;
    if (typeof options.errorsSampleRate === 'number') out.errorsSampleRate = options.errorsSampleRate;
    if (typeof options.enableViewHierarchy === 'boolean') out.enableViewHierarchy = options.enableViewHierarchy;
    if (typeof options.includeViewText === 'boolean') out.includeViewText = options.includeViewText;
    if (typeof options.maxViewNodes === 'number') out.maxViewNodes = options.maxViewNodes;
    if (typeof options.maxViewDepth === 'number') out.maxViewDepth = options.maxViewDepth;
    if (typeof options.enableReplay === 'boolean') out.enableReplay = options.enableReplay;
    if (typeof options.replayServerUrl === 'string') out.replayServerUrl = options.replayServerUrl;
    if (typeof options.enableFramesTracking === 'boolean') out.enableFramesTracking = options.enableFramesTracking;
    if (typeof options.slowFrameThresholdMs === 'number') out.slowFrameThresholdMs = options.slowFrameThresholdMs;
    if (typeof options.frozenFrameThresholdMs === 'number') out.frozenFrameThresholdMs = options.frozenFrameThresholdMs;
    if (typeof options.framesSampleRate === 'number') out.framesSampleRate = options.framesSampleRate;
    if (typeof options.enableActivityLifecycleTracing === 'boolean') out.enableActivityLifecycleTracing = options.enableActivityLifecycleTracing;
    if (typeof options.lifecycleTracingTimeoutMs === 'number') out.lifecycleTracingTimeoutMs = options.lifecycleTracingTimeoutMs;
    if (typeof options.autoCommitTransactions === 'boolean') out.autoCommitTransactions = options.autoCommitTransactions;
    if (typeof options.commitTimeoutMs === 'number') out.commitTimeoutMs = options.commitTimeoutMs;
    out.enableHiAppWatcher = (options && options.enableHiAppWatcher) !== undefined ? options.enableHiAppWatcher : true;
    out.maxAttachmentBytes = (options && options.maxAttachmentBytes) !== undefined ? options.maxAttachmentBytes : 524288;
    out.freezeBreadcrumbsMaxKeys = (options && options.freezeBreadcrumbsMaxKeys) !== undefined ? options.freezeBreadcrumbsMaxKeys : 8;
    out.crashSampleRate = (options && options.crashSampleRate) !== undefined ? options.crashSampleRate : 1.0;
    out.freezeSampleRate = (options && options.freezeSampleRate) !== undefined ? options.freezeSampleRate : 1.0;
    if (typeof options.enableUserInteractionIntegration === 'boolean') out.enableUserInteractionIntegration = options.enableUserInteractionIntegration;
    if (typeof options.enableUiBreadcrumbs === 'boolean') out.enableUiBreadcrumbs = options.enableUiBreadcrumbs;
    if (typeof options.enableAppLifecycleBreadcrumbs === 'boolean') out.enableAppLifecycleBreadcrumbs = options.enableAppLifecycleBreadcrumbs;
    if (typeof options.enableNetworkBreadcrumbs === 'boolean') out.enableNetworkBreadcrumbs = options.enableNetworkBreadcrumbs;
    if (typeof options.enableBatteryBreadcrumbs === 'boolean') out.enableBatteryBreadcrumbs = options.enableBatteryBreadcrumbs;
    if (typeof options.enableHttpBreadcrumbs === 'boolean') out.enableHttpBreadcrumbs = options.enableHttpBreadcrumbs;
    if (typeof options.enableHttpTracing === 'boolean') out.enableHttpTracing = options.enableHttpTracing;
    if (options && options.maxBreadcrumbs !== undefined) out.maxBreadcrumbs = options.maxBreadcrumbs;
    if (options && options.anrThresholdMs !== undefined) out.anrThresholdMs = options.anrThresholdMs;
    if (options && options.anrTickerIntervalMs !== undefined) out.anrTickerIntervalMs = options.anrTickerIntervalMs;
    return out;
  }

  private static ensureInit(): void {
    if (!SentryOhos._initialized) throw new Error('SentryOhos not initialized');
  }

  static async captureMessage(message: string, level: 'info' | 'warning' | 'error' = 'info', extra?: Record<string, Primitive>): Promise<void> {
    SentryOhos.ensureInit();
    if (!shouldSample(SentryOhos._options.errorsSampleRate)) return;
    // 优先走官方 SDK
    try {
      Sentry.setTag('feature', 'purchase');
      Sentry.setExtra('debug', true);
      // 不主动设置全局 user；若宿主未设置，则使用 Scope 内默认构造的全局 user
      await Sentry.captureMessage(message);
      const bc1 = new SdkBreadcrumb();
      bc1.timestamp = new Date().toISOString();
      bc1.message = message;
      bc1.category = 'log';
      bc1.level = mapCoreLevelToSentryLevel(level);
      SentryOhos.addBreadcrumb(bc1);
      await Sentry.flush(3000);
      return;
    } catch (_) {
      // 回退到自有传输
    }
    const data: MessageData = { message: message, level: level, extra: extra };
    const envelope = SentryOhos.buildEnvelope('message', data);
    const bc2 = new SdkBreadcrumb();
    bc2.timestamp = new Date().toISOString();
    bc2.message = message;
    bc2.category = 'log';
    bc2.level = mapCoreLevelToSentryLevel(level);
    SentryOhos.addBreadcrumb(bc2);
    await InternalSentrySdk.captureCoreEnvelope(envelope);
  }

  static async captureException(error: Error, extra?: Record<string, Primitive>): Promise<void> {

    SentryOhos.ensureInit();

    if (!shouldSample(SentryOhos._options.errorsSampleRate)) {

      return;
    }

    // 在异常发生前写入 error 面包屑，模仿 Android：category=error，message=异常摘要
    try {
      const bc = new SdkBreadcrumb();
      bc.timestamp = new Date().toISOString();
      bc.message = error && error.message ? error.message : 'Unhandled exception';
      bc.category = 'error';
      bc.level = SentryLevel.Error;
      const data: Record<string, string> = {};
      if (error && error.name) data['type'] = error.name;
      if (extra) {
        const keys = Object.keys(extra);
        for (let i = 0; i < keys.length; i++) {
          const k = keys[i];
          const v = (extra as Record<string, Primitive>)[k];
          data[k] = v === null || v === undefined ? String(v) : (typeof v === 'string' ? v : String(v));
        }
      }
      bc.data = data;
      SentryOhos.addBreadcrumb(bc);
    } catch (_) {}
    // 优先走官方 SDK：构造完整 SentryEvent，并先同步生成视图树与原生截图，绑定同一 event_id 一次性发送（与 Android 对齐）
    try {

      const event = SentryOhos.buildSentryEventFromError(error, extra);

      try { SentryOhos.registerErrorEventId(event.event_id as string); } catch (_) {}
      // 注入 replay_id 到 contexts.replay
      try {
        const rid = getReplayId();
        const enabled = (SentryOhos._options.enableReplay === true);
        if (enabled && typeof rid === 'string' && rid.length > 0) {
          interface ReplayCtx { replay_id?: string; id?: string }
          const rc: ReplayCtx = { replay_id: rid, id: rid };
          (event.contexts as Record<string, Object>)['replay'] = rc as Object;
          event.tags['replayId'] = rid;
          replayInfo('SentryOhos', 'event inject rid=' + rid + ' into tags/contexts');
        }
      } catch (_) {}
      // 构建视图树与原生截图（同步）
      let attachments: Array<AttachmentSpec> = [];
      try {
        const ctxMaybe: common.BaseContext | undefined = SentryOhos._baseContext;
        const outDir = '/data/storage/el2/base/haps/entry/files/sentry';
        const maxNodes = (SentryOhos._options.maxViewNodes !== undefined) ? SentryOhos._options.maxViewNodes : 1000;
        const maxDepth = (SentryOhos._options.maxViewDepth !== undefined) ? SentryOhos._options.maxViewDepth : 12;
        const includeText = SentryOhos._options.includeViewText === true;
        const vh = new ViewHierarchyProcessor();
        const res = await vh.build(ctxMaybe, outDir, { maxNodes: maxNodes, maxDepth: maxDepth, includeText: includeText, screenshotEnabled: true });

        // ✅ 直接向 event.contexts 添加新字段，不要覆盖整个 contexts
        if (res.tree) (event.contexts as Record<string, Object>)['view_hierarchy'] = res.tree as Object;
        if (res.screenshotPath) {
          const vsc = new ViewScreenshotContext(res.screenshotPath);
          (event.contexts as Record<string, Object>)['view_screenshot'] = vsc as Object;
          attachments.push({ filePath: res.screenshotPath, filename: 'screenshot.png', contentType: 'image/png', maxBytes: SentryOhos._options.maxAttachmentBytes as number });
        }


      } catch (e) {

      }
      // 使用 Hub.captureEventWithAttachments 确保单 Envelope 绑定
      try {
        const hub = Sentry.getHub() as Hub;
        if (attachments.length > 0) {
          await (hub as Hub).captureEventWithAttachments(event, attachments);
        } else {
          await Sentry.captureEvent(event);
        }
      } catch (_) {
        await Sentry.captureEvent(event);
      }
      // 标记当前 session errored 并发送 session envelope
      try {
        if (SentryOhos._session) {
          SentryOhos._session.error();
          const s = SentryOhos._session.get();
          if (s) InternalSentrySdk.captureCoreEnvelope(SentryOhos.buildSessionEnvelope('errored', s));
        }
      } catch (_) {}
      return;
    } catch (_) {
      // 回退到自有传输
    }
    const data: ExceptionData = { name: error.name, message: error.message, stack: error.stack, extra: extra };
    const envelope = SentryOhos.buildEnvelope('exception', data);
    await InternalSentrySdk.captureCoreEnvelope(envelope);
  }

  // 提供最近错误事件 id，便于 ReplayEnvelopeSender 注入 error_ids
  static registerErrorEventId(eventId?: string): void {
    if (typeof eventId === 'string' && eventId.length > 0) {
      SentryOhos._lastErrorEventId = eventId;
    }
  }

  static getLastErrorEventId(): string | undefined {
    return SentryOhos._lastErrorEventId;
  }

  static startSpan(name: string, attrs?: Object): SpanTimer {
    SentryOhos.ensureInit();
    return new SpanTimer(name, attrs);
  }

  static async finishSpan(span: SpanTimer, attrs?: Object): Promise<void> {
    SentryOhos.ensureInit();
    if (!shouldSample(SentryOhos._options.tracesSampleRate)) return;
    const ctx: SpanContext = span.end(attrs);
    try {
      // 若存在活动事务则追加 span，否则创建一次性事务
      const tm = TraceManager.get();
      if (tm.hasActive()) {
        tm.addSpan(ctx);
        return;
      } else {
        const traceId = SentryOhos.generateHexId(32);
        const spanId = SentryOhos.generateHexId(16);
        interface AttrsKnown { op?: string; status?: string }
        const known = (ctx.attrs as AttrsKnown | undefined);
        const opVal = (known && typeof known.op === 'string') ? (known.op as string) : 'default';
    const startIso = ctx.startIso !== undefined ? ctx.startIso : (ctx.startMs !== undefined ? new Date(ctx.startMs).toISOString() : new Date().toISOString());
    const endIso = ctx.endIso !== undefined ? ctx.endIso : (ctx.endMs !== undefined ? new Date(ctx.endMs).toISOString() : undefined);
        const txn = new SentryTransaction(ctx.name);
        const sp = new SdkSpan(traceId, spanId, startIso);
        sp.op = opVal;
        sp.description = ctx.name;
        sp.end_timestamp = endIso;
        if (known && typeof known.status === 'string') sp.status = known.status as string;
        txn.spans.push(sp);
        class TraceContext { trace_id?: string; span_id?: string; op?: string; origin?: string; status?: string }
        const t = new TraceContext();
        t.trace_id = traceId;
        t.span_id = spanId;
        t.op = opVal;
        t.origin = 'manual';
        t.status = 'unknown';
        txn.contexts['trace'] = t as Object;
        await Sentry.captureTransaction(txn);
        return;
      }
    } catch (_) {
      // 回退到自有传输
      const data: SpanData = { span: ctx };
      const envelope = SentryOhos.buildEnvelope('span', data);
      await InternalSentrySdk.captureCoreEnvelope(envelope);
    }
  }

  static startTransaction(name: string, op: string, timeoutMs?: number): void {
    SentryOhos.ensureInit();
    const tm = TraceManager.get();
    const effTimeout = (SentryOhos._options.commitTimeoutMs !== undefined) ? (SentryOhos._options.commitTimeoutMs as number) : 10000;
    const enabled = (SentryOhos._options.autoCommitTransactions !== undefined) ? (SentryOhos._options.autoCommitTransactions as boolean) : true;
    tm.startTransaction(name, op, typeof timeoutMs === 'number' ? timeoutMs : effTimeout, enabled);
  }

  // 运行时调整 APP_FREEZE 面包屑扩展键上限
  static setFreezeBreadcrumbsMaxKeys(n: number): void {
    const v = (typeof n === 'number' && n >= 0) ? Math.floor(n) : 8;
    SentryOhos._freezeBreadcrumbsMaxKeys = v;
  }

  // 运行时调整 HiAppEvent 采样率：FREEZE/CRASH（0..1）
  static setFreezeSampleRate(rate: number): void {
    let r = 1.0;
    if (typeof rate === 'number') {
      if (rate < 0) r = 0; else if (rate > 1) r = 1; else r = rate;
    }
    (SentryOhos._options as OhosSentryOptions).freezeSampleRate = r;
  }

  static setCrashSampleRate(rate: number): void {
    let r = 1.0;
    if (typeof rate === 'number') {
      if (rate < 0) r = 0; else if (rate > 1) r = 1; else r = rate;
    }
    (SentryOhos._options as OhosSentryOptions).crashSampleRate = r;
  }

  static async commitTransaction(): Promise<void> {
    const tm = TraceManager.get();
    const txn = tm.commit();
    if (!txn) return;
    try { await Sentry.captureTransaction(txn); } catch (_) {}
  }

  private static buildEnvelope(type: 'message' | 'exception' | 'span' | 'anr', data: EnvelopeData | AnrData): Envelope {
    // 直接使用扩展的设备和应用上下文，而不是从空对象开始
    const extDevice = collectDeviceContext();
    const extApp = collectAppContext();

    // 合并所有设备上下文字段（从 extDevice 开始）
    const device: Record<string, Primitive> = {};
    const extDeviceKeys = Object.keys(extDevice);
    for (let i = 0; i < extDeviceKeys.length; i++) {
      const key = extDeviceKeys[i];
      if (extDevice[key] !== undefined) {
        device[key] = extDevice[key];
      }
    }

    // 合并所有应用上下文字段（从 extApp 开始）
    const app: Record<string, Primitive> = {};
    const extAppKeys = Object.keys(extApp);
    for (let i = 0; i < extAppKeys.length; i++) {
      const key = extAppKeys[i];
      if (extApp[key] !== undefined) {
        app[key] = extApp[key];
      }
    }

    const crumbs = SentryOhos._breadcrumbs ? SentryOhos._breadcrumbs.snapshot() : [];
    const sess = SentryOhos._session ? SentryOhos._session.get() : undefined;
    const env: Envelope = {
      type: type,
      release: SentryOhos._options.release,
      environment: SentryOhos._options.environment,
      timestamp: new Date().toISOString(),
      device: device,
      app: app,
      data: data,
      breadcrumbs: crumbs,
      session: sess,
    };
    // 若存在当前 Replay 会话，注入 replay_id 关联（供 Web 标记 Session Replay）
    try {
      const rid = getReplayId();
      if (typeof rid === 'string' && rid.length > 0) {
        const ctxs: Record<string, Object> = env.contexts ? (env.contexts as Record<string, Object>) : {};
        // 将 replay 关联信息放入 contexts.replay，避免修改 Envelope 类型
        const replayCtx: Record<string, Object> = (ctxs['replay'] as Record<string, Object>) || {};
        replayCtx['replay_id'] = rid as Object;
        ctxs['replay'] = replayCtx as Object;
        env.contexts = ctxs;
      }
    } catch (_) {}
    // beforeSend 扩展：注入视图树与截图
    try {
      if (SentryOhos._options.enableViewHierarchy) {
        const contextMaybe: common.BaseContext | undefined = undefined; // 由集成方传入更合适的 UIAbility context（后续扩展）
        const outDir = '/data/storage/el2/base/haps/entry/files/sentry';
        const maxNodes = SentryOhos._options.maxViewNodes !== undefined ? SentryOhos._options.maxViewNodes : 1000;
        const maxDepth = SentryOhos._options.maxViewDepth !== undefined ? SentryOhos._options.maxViewDepth : 12;
        const includeText = SentryOhos._options.includeViewText === true;
        const vh = new ViewHierarchyProcessor();
        // 非阻塞：不影响事件主路径
        vh.build(contextMaybe, outDir, { maxNodes: maxNodes, maxDepth: maxDepth, includeText: includeText, screenshotEnabled: true })
          .then((res) => {
            try {
              const ctx: Record<string, Object> = env.contexts ? env.contexts as Record<string, Object> : {};
              if (res.tree) ctx['view_hierarchy'] = res.tree as Object;
              if (res.screenshotPath) {
                const vsc = new ViewScreenshotContext(res.screenshotPath);
                ctx['view_screenshot'] = vsc as Object;
                // 同步作为附件发送，确保后台可预览
                try { SentryOhos.sendAttachment(res.screenshotPath, 'screenshot.png', 'image/png'); } catch (_) {}
              }
              env.contexts = ctx;
            } catch (e) {}
          })
          .catch(() => {});
      }
    } catch (_) {}
    // Harmony core 不再承载 Envelope 级 beforeSend，事件级 beforeSend 已在 Hub 里处理
    return env;
  }

  static addBreadcrumb(b: CoreBreadcrumb): void {
    if (SentryOhos._breadcrumbs) SentryOhos._breadcrumbs.add(b);
    // 同步到官方 SDK 的 Scope，便于与 Android 展示一致
    try {
      const sdkB = toSdkBreadcrumb(b);
      Sentry.addBreadcrumb(sdkB);
    } catch (_) {}
  }

  private static buildSentryEventFromError(error: Error, extra?: Record<string, Primitive>): SentryEvent {
    const event = new SentryEvent(error && error.message ? error.message : 'Error');
    event.level = SentryLevel.Error;
    // mechanism
    const mech = new Mechanism();
    mech.type = 'generic';
    mech.handled = false;
    // stacktrace frames
    const frames = SentryOhos.parseStackToFrames(error && typeof error.stack === 'string' ? error.stack : undefined);
    // 反转为“旧→新”，贴近 Raw stack trace 展示
    const st = new SentryStackTrace(frames.reverse());
    // exception
    const ex = new SentryException();
    ex.type = error && error.name ? error.name : 'Error';
    ex.value = error && error.message ? error.message : 'Unknown error';
    ex.stacktrace = st;
    ex.mechanism = mech;
    ex.threadId = 1;
    event.exceptions = [ex];
    // threads（主线程占位）
    const th = new SentryThread();
    th.id = 1;
    th.name = 'main';
    th.current = true;
    th.crashed = true;
    th.stacktrace = st;
    // 线程字段增强
    try {
      th.main = true;
      th.daemon = false;
      th.priority = 0;
      th.state = 'RUNNABLE';
      const td: Record<string, string> = {};
      td['thread.name'] = 'main';
      td['thread.id'] = '1';
      th.data = td;
    } catch (_) {}
    event.threads = [th];
    // 附带当前活动 trace 上下文（如有）
    try {
      const tm = TraceManager.get();
      const snap = tm.getActiveTraceSnapshot();
      if (snap) {
        class TraceCtxExt { trace_id?: string; span_id?: string; op?: string; status?: string; origin?: string; data?: Record<string, string> }
        const t = new TraceCtxExt();
        t.trace_id = snap.trace_id;
        t.span_id = snap.span_id;
        t.op = snap.op;
        t.status = snap.status;
        t.origin = 'error';
        const td: Record<string, string> = {};
        td['thread.name'] = 'main';
        td['thread.id'] = '1';
        t.data = td;
        event.contexts['trace'] = t as Object;
      }
    } catch (_) {}
    // extras
    if (extra) {
      const keys = Object.keys(extra);
      for (let i = 0; i < keys.length; i++) {
        const k = keys[i];
        const v = (extra as Record<string, Primitive>)[k];
        event.extras[k] = v === null || v === undefined ? String(v) : (typeof v === 'string' ? v : String(v));
      }
    }
    // 处理 error.cause 链，构造 mechanism: chained
    try {
      const chain: Array<SentryException> = [];
      interface ErrorWithCause { cause?: Error }
      const errWithCause = error as ErrorWithCause;
      let cursor: Error | undefined = errWithCause.cause;
      while (cursor) {
        const framesCause = SentryOhos.parseStackToFrames(typeof cursor.stack === 'string' ? cursor.stack : undefined).reverse();
        const stCause = new SentryStackTrace(framesCause);
        const exCause = new SentryException();
        exCause.type = cursor.name || 'Error';
        exCause.value = cursor.message || 'Unknown error';
        const mechCause = new Mechanism();
        mechCause.type = 'chained';
        mechCause.handled = false;
        exCause.mechanism = mechCause;
        exCause.stacktrace = stCause;
        chain.push(exCause);
        const curWithCause = cursor as ErrorWithCause;
        cursor = curWithCause.cause;
      }
      if (chain.length > 0) {
        // 规范上最新异常在数组最后；我们将现有主异常放在最后，前置 cause 链
        event.exceptions = chain.concat(event.exceptions);
      }
    } catch (_) {}
    // 即时采集并注入 contexts（device/os/app/runtime）
    try {
      const deviceCtx = collectDeviceContext();
      const appCtx = collectAppContext();
      const runtimeCtx = collectRuntimeContext();

      // 记录收集到的上下文字段数量和内容
      // ✅ 先合并所有 collectDeviceContext 中的字段
      const d: Record<string, Object> = {};
      const deviceKeys = Object.keys(deviceCtx);
      for (let i = 0; i < deviceKeys.length; i++) {
        const key = deviceKeys[i];
        if (deviceCtx[key] !== undefined) {
          d[key] = deviceCtx[key] as Object;
        }
      }
      if (typeof runtimeCtx.batteryLevel === 'number') d['battery_level'] = runtimeCtx.batteryLevel as Object;
      if (typeof runtimeCtx.isCharging === 'boolean') d['charging'] = runtimeCtx.isCharging as Object;
      if (typeof runtimeCtx.memoryTotalMb === 'number') d['memory_size'] = Math.floor(runtimeCtx.memoryTotalMb * 1024 * 1024) as Object;
      if (typeof runtimeCtx.memoryTotalMb === 'number' && typeof runtimeCtx.memoryUsedMb === 'number') {
        const freeMb = runtimeCtx.memoryTotalMb - runtimeCtx.memoryUsedMb;
        if (freeMb >= 0) d['free_memory'] = Math.floor(freeMb * 1024 * 1024) as Object;
      }
      if (typeof runtimeCtx.lowMemory === 'boolean') d['low_memory'] = runtimeCtx.lowMemory as Object;
      if (typeof runtimeCtx.storageTotalGb === 'number') d['storage_size'] = Math.floor(runtimeCtx.storageTotalGb * 1024 * 1024 * 1024) as Object;
      if (typeof runtimeCtx.storageFreeGb === 'number') d['free_storage'] = Math.floor(runtimeCtx.storageFreeGb * 1024 * 1024 * 1024) as Object;
      if (typeof runtimeCtx.screenWidthPx === 'number') d['screen_width_pixels'] = runtimeCtx.screenWidthPx as Object;
      if (typeof runtimeCtx.screenHeightPx === 'number') d['screen_height_pixels'] = runtimeCtx.screenHeightPx as Object;
      if (typeof runtimeCtx.screenDensity === 'number') d['screen_density'] = runtimeCtx.screenDensity as Object;
      if (typeof runtimeCtx.screenDpi === 'number') d['screen_dpi'] = runtimeCtx.screenDpi as Object;
      if (typeof runtimeCtx.networkType === 'string') {
        d['connection_type'] = runtimeCtx.networkType as Object;
        d['online'] = (runtimeCtx.networkType !== 'none') as Object;
      }
      if (typeof (deviceCtx['archs']) === 'string') { const arr = (deviceCtx['archs'] as string).split(','); d['archs'] = arr as Object; }
      if (typeof (deviceCtx['chipset']) === 'string') d['chipset'] = deviceCtx['chipset'] as Object;
      // battery_temperature：如系统 API 不支持，使用默认 28（参考电池信息文档占位）
      if (d['battery_temperature'] === undefined) d['battery_temperature'] = 28 as Object;
      const ltz = getLocaleTimezone();
      if (ltz.locale) d['locale'] = ltz.locale as Object;
      if (ltz.timezone) d['timezone'] = ltz.timezone as Object;
      event.contexts['device'] = d as Object;
      const o: Record<string, Object> = {};
      o['name'] = 'OpenHarmony' as Object;
      if (typeof (deviceCtx['osVersion']) === 'string') o['version'] = deviceCtx['osVersion'] as Object;
      const kernel = getKernelVersion();
      if (kernel) o['kernelVersion'] = kernel as Object;
      const rootedMaybe = detectRooted();
      if (typeof rootedMaybe === 'boolean') o['rooted'] = (rootedMaybe ? true : false) as Object;
      if (typeof (deviceCtx['build']) === 'string') o['build'] = deviceCtx['build'] as Object;
      if (typeof (deviceCtx['softwareModel']) === 'string') o['softwareModel'] = deviceCtx['softwareModel'] as Object;
      if (typeof (deviceCtx['buildFeatures']) === 'string') o['buildFeatures'] = deviceCtx['buildFeatures'] as Object;
      event.contexts['os'] = o as Object;
      const a: Record<string, Object> = {};
      if (typeof (appCtx['appName']) === 'string') a['app_name'] = appCtx['appName'] as Object;
      if (typeof (appCtx['packageName']) === 'string') a['app_identifier'] = appCtx['packageName'] as Object;
      if (typeof (appCtx['appVersion']) === 'string') a['app_version'] = appCtx['appVersion'] as Object;
      if (appCtx['appBuild'] !== undefined) a['app_build'] = String(appCtx['appBuild']) as Object;
      a['in_foreground'] = (SentryOhos._isInForeground ? true : false) as Object;
      if (typeof (appCtx['permissionsCsv']) === 'string') { const perms = (appCtx['permissionsCsv'] as string).split(','); a['permissions'] = perms as Object; }
      event.contexts['app'] = a as Object;
      const rt: Record<string, Primitive> = {};
      if (runtimeCtx.networkType !== undefined) rt['networkType'] = runtimeCtx.networkType;
      if (runtimeCtx.batteryLevel !== undefined) rt['batteryLevel'] = runtimeCtx.batteryLevel;
      if (runtimeCtx.isCharging !== undefined) rt['isCharging'] = runtimeCtx.isCharging;
      if (runtimeCtx.memoryUsedMb !== undefined) rt['memoryUsedMb'] = runtimeCtx.memoryUsedMb;
      if (runtimeCtx.memoryTotalMb !== undefined) rt['memoryTotalMb'] = runtimeCtx.memoryTotalMb;
      if (runtimeCtx.freeMemoryMb !== undefined) rt['freeMemoryMb'] = runtimeCtx.freeMemoryMb;
      if (runtimeCtx.online !== undefined) rt['online'] = runtimeCtx.online;
      if (runtimeCtx.screenDpi !== undefined) rt['screenDpi'] = runtimeCtx.screenDpi;
      if (runtimeCtx.screenDensity !== undefined) rt['screenDensity'] = runtimeCtx.screenDensity;
      if (runtimeCtx.screenWidthPx !== undefined) rt['screenWidthPx'] = runtimeCtx.screenWidthPx;
      if (runtimeCtx.screenHeightPx !== undefined) rt['screenHeightPx'] = runtimeCtx.screenHeightPx;
      if (runtimeCtx.storageTotalGb !== undefined) rt['storageTotalGb'] = runtimeCtx.storageTotalGb;
      if (runtimeCtx.storageFreeGb !== undefined) rt['storageFreeGb'] = runtimeCtx.storageFreeGb;
      (event.contexts as Record<string, Object>)['runtime'] = rt as Object;
      event.tags['is_foreground'] = String(SentryOhos._isInForeground);
    } catch (_) {}
    return event;
  }

  private static parseStackToFrames(stack?: string): Array<SentryStackFrame> {
    const frames: Array<SentryStackFrame> = [];
    if (!stack) return frames;
    // 常见格式："at function (file:line:col)" 或 "at file:line:col"
    const lines = stack.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const raw = lines[i].trim();
      if (raw.length === 0) continue;
      const frame = SentryOhos.parseFrameLine(raw);
      if (frame) frames.push(frame);
    }
    return frames;
  }

  private static parseFrameLine(line: string): SentryStackFrame | undefined {
    // 1) at func (file:line:col)
    const re1 = /^at\s+([^\s]+)\s*\(([^:]+):(\d+):(\d+)\)$/;
    const m1 = line.match(re1);
    if (m1) {
      const fn = m1[1];
      const file = m1[2];
      const ln = parseInt(m1[3]);
      const col = parseInt(m1[4]);
      const f = new SentryStackFrame();
      f.function = fn;
      f.filename = file;
      f.lineno = isNaN(ln) ? undefined : ln;
      f.colno = isNaN(col) ? undefined : col;
      f.in_app = true;
      return f;
    }
    // 2) at file:line:col
    const re2 = /^at\s+([^:]+):(\d+):(\d+)$/;
    const m2 = line.match(re2);
    if (m2) {
      const file = m2[1];
      const ln = parseInt(m2[2]);
      const col = parseInt(m2[3]);
      const f = new SentryStackFrame();
      f.filename = file;
      f.lineno = isNaN(ln) ? undefined : ln;
      f.colno = isNaN(col) ? undefined : col;
      f.in_app = true;
      return f;
    }
    // 3) 其它：仅保留原行
    const f = new SentryStackFrame();
    f.filename = line;
    return f;
  }

  private static generateHexId(len: number): string {
    const hex = '0123456789abcdef';
    let out = '';
    for (let i = 0; i < len; i++) {
      const n = Math.floor(Math.random() * 16);
      out += hex.charAt(n);
    }
    return out;
  }

  static getBreadcrumbStore(): BreadcrumbStore | null {
    return SentryOhos._breadcrumbs;
  }

  static startSession(): void {
    if (SentryOhos._session) {
      const s = SentryOhos._session.start();
      InternalSentrySdk.captureCoreEnvelope(SentryOhos.buildSessionEnvelope('start', s));
    }
  }

  static endSession(): void {
    if (SentryOhos._session) {
      const s = SentryOhos._session.end();
      if (s) InternalSentrySdk.captureCoreEnvelope(SentryOhos.buildSessionEnvelope('end', s));
    }
  }

  static markAppLaunched(): void {
    if (SentryOhos._appStart) SentryOhos._appStart.markAppLaunched();
  }

  static markFirstPageBuilt(): void {
    if (!SentryOhos._appStart) return;
    const timing = SentryOhos._appStart.markFirstPageBuilt();
    if (timing.coldStartMs !== undefined) {
      const extra: Record<string, Primitive> = {};
      extra['coldStartMs'] = timing.coldStartMs;
      SentryOhos.captureMessage('Cold start', 'info', extra);
    }
  }

  // 附件发送（对齐 Android Demo 的 Attachment 示例）
  static async sendAttachment(filePath: string, filename: string, contentType?: string): Promise<void> {
    try {
      const hub = Sentry.getHub();
      type AttachmentSender = (p: string, n: string, c?: string, maxBytes?: number) => Promise<void>;
      interface TransportWithAttach { sendAttachment?: AttachmentSender }
      const t = (hub.transport as TransportWithAttach);
      if (t && typeof t.sendAttachment === 'function') {
        const ct = contentType !== undefined ? contentType : 'text/plain';
        const maxBytes = (SentryOhos._options.maxAttachmentBytes as number) || 524288;
        await t.sendAttachment(filePath, filename, ct, maxBytes);
      }
    } catch (_) {}
  }

  static setForeground(isForeground: boolean): void {
    SentryOhos._isInForeground = isForeground;
  }

  // 供 UIAbility 回调安全调用，不影响类型定义
  static ['__setForeground'](isForeground: boolean): void {
    SentryOhos.setForeground(isForeground);
  }

  private static async send(payload: Envelope): Promise<void> {
    if (!SentryOhos._transport) return;
    try {
      await SentryOhos._transport.send(payload);
    } catch (e) {
      HarmonyLogger.error('send failed', 'caught');
    }
  }

  // 宿主设置 BaseContext 后，可用于启动回放与截图
  static setBaseContext(ctx: common.BaseContext): void {
    SentryOhos._baseContext = ctx;
    try {
      if (SentryOhos._initialized && SentryOhos._options.enableReplay && SentryOhos._options.replayServerUrl) {
        startReplay({ context: ctx, serverUrl: SentryOhos._options.replayServerUrl, frameIntervalMs: 500, segmentMs: 5000, maskAllImages: true, enableScreenFrames: true, sessionSampleRate: 0.1, onErrorSampleRate: 1.0 });
      }
    } catch (_) {}
    // 注册 TraceManager 自动提交钩子
    try {
      type AutoCommitHook = (t: SentryTransaction) => Promise<void>;
      interface TMWithHook { onAutoCommit?: AutoCommitHook }
      const self: TMWithHook = TraceManager as TMWithHook;
      self.onAutoCommit = async (t: SentryTransaction): Promise<void> => {
        try { await Sentry.captureTransaction(t); } catch (_) {}
      };
    } catch (_) {}
  }

  // ---- HiAppEvent Watcher：APP_CRASH → SentryEvent ----
  private static installHiAppWatcher(): void {
    // 简易防重入
    try {
      const filters: Array<hiAppEvent.AppEventFilter> = [{ domain: 'OS', names: ['APP_CRASH','APP_FREEZE'] }];
      interface AppCrashParams {
        exception?: object;
        hilog?: Array<object>;
        external_log?: string;
        foreground?: boolean;
        bundle_version?: string;
        duration?: number;
        durationMs?: number;
        reason?: string;
        pid?: number | string;
        uid?: number | string;
        stack?: string;
        stackSummary?: string;
      }
      const watcher: hiAppEvent.Watcher = {
        name: 'sentry_hia_watcher',
        appEventFilters: filters,
        onReceive: async (_domain: string, appEventGroups: Array<hiAppEvent.AppEventGroup>) => {
          try {
            if (!appEventGroups || appEventGroups.length === 0) return;
            for (let gi = 0; gi < appEventGroups.length; gi++) {
              const g = appEventGroups[gi];
              const infos = g && g.appEventInfos ? g.appEventInfos : [];
              for (let ii = 0; ii < infos.length; ii++) {
                const info = infos[ii];
                const eventName = typeof info.name === 'string' ? info.name : '';
                const params = (info.params as AppCrashParams) || {} as AppCrashParams;
                // APP_FREEZE 转换为完整的ANR事件（根据华为官方指南）
                if (eventName === 'APP_FREEZE') {
                  // 检查是否在debug模式下允许上报
                  const currentDebug = (SentryOhos._options.debug === true);
                  const currentAnrReportInDebug = (SentryOhos._options.anrReportInDebug === true);
                  if (currentDebug && !currentAnrReportInDebug) {
                    continue;
                  }
                  // 采样
                  const sr = (SentryOhos._options.freezeSampleRate as number) || 1.0;
                  if (!shouldSample(sr)) continue;

                  const duration = (params.duration !== undefined) ? params.duration : params.durationMs;
                  const durationMs = typeof duration === 'number' ? duration : 5000; // 默认5秒
                  const foreground = typeof params.foreground === 'boolean' ? params.foreground : SentryOhos._isInForeground;

                  // 创建完整的ANR事件（与主动检测路径一致）
                  try {
                    const crumbsCore = SentryOhos._breadcrumbs ? SentryOhos._breadcrumbs.snapshot() : [];
                    const crumbs: Array<SdkBreadcrumb> = [];
                    for (let i = 0; i < crumbsCore.length; i++) {
                      crumbs.push(toSdkBreadcrumb(crumbsCore[i]));
                    }

                    const event = new SentryEvent('Application Not Responding');
                    event.level = SentryLevel.Fatal;
                    const fp: Array<string> = [];
                    fp.push('{{ default }}');
                    fp.push(foreground ? 'foreground-anr' : 'background-anr');
                    event.fingerprint = fp;

                    // 异常机制对齐 Android
                    const mech = new Mechanism();
                    mech.type = 'AppExitInfo';
                    mech.handled = false;
                    const ex = new SentryException();
                    ex.type = 'ApplicationNotResponding';
                    ex.value = 'ANR';
                    ex.mechanism = mech;
                    event.exceptions = [ex];
                    event.extras['blockedForMs'] = String(durationMs);

                    // 线程快照：使用系统提供的stack信息
                    try {
                      const th = new SentryThread();
                      th.id = 1;
                      th.name = 'main';
                      th.current = true;
                      th.crashed = true;
                      th.main = true;
                      th.state = 'Blocked';

                      const stack = (params.stack !== undefined) ? params.stack : params.stackSummary;
                      if (typeof stack === 'string' && stack.length > 0) {
                        // 解析系统提供的stack trace
                        const frames = SentryOhos.parseStackToFrames(stack);
                        const st = new SentryStackTrace(frames);
                        th.stacktrace = st;
                      } else {
                        // 如果没有stack，使用简化版本
                        const frames: Array<SentryStackFrame> = [];
                        const fTop = new SentryStackFrame();
                        fTop.function = 'hiAppEvent.APP_FREEZE';
                        fTop.module = 'system';
                        fTop.in_app = false;
                        frames.push(fTop);
                        const st = new SentryStackTrace(frames);
                        th.stacktrace = st;
                      }
                      event.threads = [th];
                    } catch (_) {}

                    // 注入 contexts
                    try {
                      const deviceCtx = collectDeviceContext();
                      const appCtx = collectAppContext();
                      const runtimeCtx = collectRuntimeContext();

                      const devObj: Record<string, Primitive> = {};
                      const deviceKeys = Object.keys(deviceCtx);
                      for (let i = 0; i < deviceKeys.length; i++) {
                        const k = deviceKeys[i];
                        if (deviceCtx[k] !== undefined) devObj[k] = deviceCtx[k];
                      }
                      (event.contexts as Record<string, Object>)['device'] = devObj as Object;

                      const osCtx: Record<string, Primitive> = {};
                      osCtx['name'] = 'OpenHarmony';
                      if (typeof (deviceCtx['osVersion']) === 'string') osCtx['version'] = deviceCtx['osVersion'] as string;
                      (event.contexts as Record<string, Object>)['os'] = osCtx as Object;

                      const appOut: Record<string, Primitive> = {};
                      if (appCtx['appName'] !== undefined) appOut['app_name'] = appCtx['appName'] as string;
                      appOut['in_foreground'] = foreground;
                      (event.contexts as Record<string, Object>)['app'] = appOut as Object;

                      const rt: Record<string, Primitive> = {};
                      if (runtimeCtx.networkType !== undefined) rt['networkType'] = runtimeCtx.networkType;
                      (event.contexts as Record<string, Object>)['runtime'] = rt as Object;

                      event.tags['is_foreground'] = String(foreground);

                      // 添加系统提供的额外信息
                      if (typeof params.reason === 'string') event.tags['freeze_reason'] = params.reason;
                      if (typeof params.pid === 'number' || typeof params.pid === 'string') event.tags['pid'] = String(params.pid);
                      if (typeof params.uid === 'number' || typeof params.uid === 'string') event.tags['uid'] = String(params.uid);
                    } catch (_) {}

                    event.breadcrumbs = crumbs;

                    // 缓存并发送事件
                    try {
                      const hub = Sentry.getHub();
                      interface HubWithCache { cache: FileEnvelopeCache | null }
                      const h = hub as HubWithCache;
                      if (h && h.cache) {
                        try {
                          h.cache.store(event);
                        } catch (cacheErr) {
                          // 缓存失败，非关键
                        }
                      }
                    } catch (_) {}

                    // 发送事件
                    Sentry.captureEvent(event).catch((err: Error) => {
                      console.error(`[Sentry] SentryOhos APP_FREEZE event send failed: ${err}`);
                    });
                  } catch (err) {
                    console.error(`[Sentry] SentryOhos ERROR creating APP_FREEZE ANR event: ${err}`);
                  }

                  // 同时记录breadcrumb用于上下文
                  try {
                    const bc = new SdkBreadcrumb();
                    bc.timestamp = new Date().toISOString();
                    bc.message = 'App freeze detected (hiAppEvent)';
                    bc.category = 'device.freeze';
                    bc.level = SentryLevel.Warning;
                    const dataRec: Record<string, string> = {};
                    if (typeof durationMs === 'number') dataRec['durationMs'] = String(durationMs);
                    const reason = params.reason;
                    if (typeof reason === 'string') dataRec['reason'] = reason;
                    bc.data = dataRec;
                    SentryOhos.addBreadcrumb(bc);
                  } catch (_) {}

                  continue;
                }
                // 采样：APP_CRASH
                const csr = (SentryOhos._options.crashSampleRate as number) || 1.0;
                if (!shouldSample(csr)) continue;
                const exObj = (params.exception as Record<string, Object>) || {} as Record<string, Object>;
                const exNameV = (exObj as Record<string, Object>)['name'];
                const exMsgV = (exObj as Record<string, Object>)['message'];
                const exStackV = (exObj as Record<string, Object>)['stack'];
                const exName = typeof exNameV === 'string' ? exNameV : 'Error';
                const exMsg = typeof exMsgV === 'string' ? exMsgV : 'App crash';
                const exStack = typeof exStackV === 'string' ? exStackV : undefined;
                const ev = new SentryEvent(exMsg);
                ev.level = SentryLevel.Error;
                const mech = new Mechanism();
                mech.type = 'crash';
                mech.handled = false;
                const ex = new SentryException();
                ex.type = exName;
                ex.value = exMsg;
                if (exStack) {
                  const frames = SentryOhos.parseStackToFrames(exStack).reverse();
                  const st = new SentryStackTrace(frames);
                  ex.stacktrace = st;
                }
                ex.mechanism = mech;
                ev.exceptions = [ex];
                const hilogObj = params.hilog;
                if (Array.isArray(hilogObj)) {
                  const max = Math.min(50, (hilogObj as Array<Object>).length);
                  for (let i = 0; i < max; i++) {
                    const line = String((hilogObj as Array<Object>)[i]);
                    const bc = new SdkBreadcrumb();
                    bc.timestamp = new Date().toISOString();
                    bc.message = line;
                    bc.category = 'log';
                    bc.level = SentryLevel.Info;
                    SentryOhos.addBreadcrumb(bc);
                  }
                }
                const extLog = params.external_log;
                if (extLog !== undefined) {
                  const path = String(extLog);
                  ev.extras['external_log'] = path;
                  // 作为附件发送（独立 envelope attachment item），截断到 maxAttachmentBytes
                  try {
                    const hub = Sentry.getHub();
                    type AttachmentSender = (p: string, n: string, c?: string, maxBytes?: number) => Promise<void>;
                    interface TransportWithAttach { sendAttachment?: AttachmentSender }
                    const t = hub.transport as TransportWithAttach;
                    if (t && typeof t.sendAttachment === 'function') {
                      const name = 'external_log.txt';
                      await t.sendAttachment(path, name, 'text/plain', SentryOhos._options.maxAttachmentBytes as number);
                    }
                  } catch (_) {}
                }
                if (typeof params.foreground === 'boolean') ev.tags['in_foreground'] = String(params.foreground);
                if (typeof params.bundle_version === 'string') ev.tags['app_version'] = String(params.bundle_version);
                Sentry.captureEvent(ev);
              }
            }
          } catch (_) {}
        }
      };
      try { hiAppEvent.addWatcher(watcher); } catch (_) {}
    } catch (_) {}
  }

  private static buildSessionEnvelope(kind: 'start' | 'end' | 'errored', s: SessionState): Envelope {
    // 显式构造 data，避免未声明字面量
    const dataObj: Record<string, Primitive> = {};
    dataObj['id'] = s.id;
    dataObj['started'] = new Date(s.startedMs).toISOString();
    if (s.endedMs !== undefined) dataObj['ended'] = new Date(s.endedMs).toISOString();
    dataObj['errors'] = s.errors;
    dataObj['status'] = kind === 'end' ? 'exited' : (kind === 'errored' ? 'errored' : 'ok');

    // session envelope 不需要 device/app/breadcrumbs，但为兼容当前 Envelope 结构，填入空对象/空数组
    const deviceRec: Record<string, Primitive> = {};
    const appRec: Record<string, Primitive> = {};
    const env: Envelope = {
      type: 'session',
      release: SentryOhos._options.release,
      environment: SentryOhos._options.environment,
      timestamp: new Date().toISOString(),
      device: deviceRec,
      app: appRec,
      data: dataObj,
      breadcrumbs: [],
    };
    return env;
  }
}

export default SentryOhos;


