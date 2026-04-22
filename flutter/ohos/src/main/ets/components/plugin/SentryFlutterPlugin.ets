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

import {
  AbilityAware,
  AbilityPluginBinding,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { AbilityLifecycleCallback, common } from '@kit.AbilityKit';
import UIAbility from '@ohos.app.ability.UIAbility'

import fs from '@ohos.file.fs';
import fileio from '@ohos.fileio';
import display from '@ohos.display';

import { SentryOhos,
  Breadcrumb,
  FileEnvelopeCache,
  DebugImagesLoader,
  DebugImage,
  installGlobalErrorHandler,
  startReplay,
  stopReplay,
  pauseReplay,
  resumeReplay,
  uploadReplay,
  ReplayStartOptions,
  HttpTransportFactory,
  Sentry,
  SentryLevel,
  SentryOptions,
  User,
  onAppForeground,
  onAppBackground,
  updateReplayContext,
  captureReplayOnError,
  configureReplaySampling,
  getReplayId,
  setReplayScrollingState
} from "sentry_ohos"
import { pushFlutterFrame } from 'sentry_ohos/src/main/ets/sentry_ohos_replay/api';
import NdkSample from 'libentry.so';

import { SentryFlutterReplayRecorder } from './SentryFlutterReplayRecorder';
import { InternalSentrySdk } from 'sentry_ohos/src/main/ets/core/InternalSentrySdk';
import { ScreenshotRecorderConfig } from 'sentry_ohos/src/main/ets/sentry_ohos_replay/ScreenshotRecorderConfig';
import { collectDeviceContext, collectAppContext, collectRuntimeContext, getKernelVersion, getProcessorCount, getLocaleTimezone, detectRooted } from 'sentry_ohos/src/main/ets/core/Context';
import errorManager from '@ohos.app.ability.errorManager';
export { Breadcrumb, FileEnvelopeCache, HttpTransportFactory, Sentry, SentryLevel, SentryOptions, User, SentryOhos }

const Error_Code = '404';
const Message = 'Bad Request';
const Details = 'Request parameter error.'

// Interface for globalThis with gfxSurface property and optional module loaders
interface SystemModuleLoader {
  loadModule?: (name: string) => Object;
}

interface ModuleCacheLike {
  get?: (key: string) => Object | undefined;
}

interface FileDirProvider {
  filesDir?: string;
  cacheDir?: string;
}

interface GlobalThisWithGfxSurface {
  gfxSurface?: Object;
  requireNapi?: (module: string) => Object;
  require?: (module: string) => Object;
  system?: SystemModuleLoader | undefined;
  __modules__?: ModuleCacheLike;
}

class FlutterFrameMeta {
  public width: number;
  public height: number;
  public stride: number;
  public timestamp: number;
  public byteLength: number;

  constructor(width: number, height: number, stride: number, timestamp: number, byteLength: number) {
    this.width = width;
    this.height = height;
    this.stride = stride;
    this.timestamp = timestamp;
    this.byteLength = byteLength;
  }
}

// Interface for UIAbility with getContext method
interface UIAbilityWithGetContext {
  getContext?: () => common.BaseContext | null;
}

// Interface for UIAbility with context property
interface UIAbilityWithContext {
  context?: common.BaseContext;
}

/** SentryFlutterPlugin **/
export default class SentryFlutterPlugin extends AbilityLifecycleCallback implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private channel: MethodChannel | null = null;
  private applicationContext: common.Context | null = null;
  private pluginRegistrationTime: number | null = null;
  private activity: UIAbility | null = null;
  static readonly sdkName: string = "sentry-ohos";
  private static readonly REPLAY_FRAME_CHANNEL: string = 'io.sentry.sessionReplay/native';
  binding: FlutterPluginBinding | null = null;
  private replayEnabled: boolean = false;
  private autoSessionEnabled: boolean = true;
  private pluginDebug: boolean = false;
  private lifecycleCallbackId: number = -1;
  private replayRecorder: SentryFlutterReplayRecorder | null = null;
  private abilityContext: common.BaseContext | null = null;
  private abilityContextProvider?: common.Context;
  private replayStartRequested: boolean = false;
  private replayStarted: boolean = false;
  private replayServerUrl: string | null = null;
  private replaySessionSampleRate: number = 0;
  private replayOnErrorSampleRate: number = 0;
  private replayFrameIntervalMs: number = 1000;
  private replaySegmentMs: number = 5000;
  private pendingReplayErrorEventId: string | undefined = undefined;
  private gfxSurfaceReady: boolean = false;
  private replayWaitingForUiCtxLogged: boolean = false;
  // 灰度：默认开启 envelope 改写注入，因 Flutter 事件多经由 raw envelope 通道
  // 后续若统一至传输层，再改回 false
  private enableEnvelopeInject: boolean = true;
  private replayFrameChannel: MethodChannel | null = null;
  private frameQueue: Array<Record<string, Object | null | undefined>> = [];
  private queueProcessing: boolean = false;
  private readonly maxFramesPerDrain: number = 1; // Process one frame per drain
  private readonly maxQueuedFrames: number = 10; // Increased to allow more frames during scrolling
  private readonly queueDrainDelayMs: number = 12; // Increased from 8 to 12ms, reduce JS thread blocking
  private isScrolling: boolean = false; // Flag to pause encoding during scrolling
  private encodingPaused: boolean = false; // Flag to pause encoding processing

  private normalizeReplayId(id: string): string {
    // 生成32位小写十六进制：将字符的UTF-16编码累加映射为hex，保证稳定性
    const hex: Array<string> = [];
    let acc = 0;
    for (let i = 0; i < id.length; i++) {
      acc = (acc * 131 + (id.charCodeAt(i) & 0xFFFF)) >>> 0;
      const h = (acc & 0xFF).toString(16);
      hex.push(h.length === 1 ? ('0' + h) : h);
      if (hex.length >= 32) break;
    }
    while (hex.length < 32) hex.push('0');
    return hex.join('').slice(0, 32).toLowerCase();
  }
  // 缓存初始化前的未处理异常，待 SDK 初始化完成后统一上报
  private pendingUnhandledErrors: Array<Error> = [];
  private errorManagerId: number = 0;
  // 原生 SDK 初始化生命周期状态，替代单一布尔标志，使状态语义更明确：
  //  - 'uninitialized': 从未调用过 init（或 init 失败后回退）
  //  - 'initializing' : 正在执行 SentryOhos.init(...)
  //  - 'initialized'  : installGlobalErrorHandler 已激活，errorManager 不再重复上报
  // 尽管 ArkTS 单线程模型通常保证同一宏任务内读写顺序，
  // 但使用枚举字符串能在多 async 任务交错时提供更清晰的意图表达。
  private nativeSdkState: 'uninitialized' | 'initializing' | 'initialized' = 'uninitialized';
  // 保留旧 getter 语义：只有当已完成初始化时才视为“native 已就绪”，
  // 用于 onUnhandledException 中的重复上报判定。
  private get nativeSdkInitialized(): boolean {
    return this.nativeSdkState === 'initialized';
  }
  // ArkTS helper: check non-empty object safely
  private isNonEmptyRecord(o: Object | null | undefined): boolean {
    if (!o || typeof o !== 'object') return false;
    const rec = o as Record<string, Object>;
    return Object.keys(rec).length > 0;
  }

  private isSurfaceApiCandidate(candidate: Object): boolean {
    const rec = candidate as Record<string, Object>;
    const createFn = rec['createSurfaceFromId'] as Object | undefined;
    return typeof createFn === 'function';
  }

  private describeObjectKeys(obj: Object): string {
    try {
      const names = Object.getOwnPropertyNames(obj as Object);
      if (names.length === 0) {
        return '[no-own-keys]';
      }
      return names.join(',');
    } catch (err) {
      return 'describeKeysError:' + String(err);
    }
  }

  private extractSurfaceApi(moduleObj: Object | null, source: string): Object | null {
    if (!moduleObj) {
      console.warn('[SessionReplayVideo] ' + source + ' returned null/undefined module');
      return null;
    }
    const typeDesc = typeof moduleObj;
    console.info('[SessionReplayVideo] ' + source + ' typeof=' + typeDesc);
    if (typeDesc !== 'object') {
      console.warn('[SessionReplayVideo] ' + source + ' returned non-object module: type=' + typeDesc);
      return null;
    }
    const keyDesc = this.describeObjectKeys(moduleObj);
    console.info('[SessionReplayVideo] ' + source + ' keys=' + keyDesc);
    if (this.isSurfaceApiCandidate(moduleObj)) {
      console.info('[SessionReplayVideo] ' + source + ' exposes createSurfaceFromId directly');
      return moduleObj;
    }
    const moduleRecord = moduleObj as Record<string, Object>;
    const defaultExport = moduleRecord['default'];
    if (defaultExport && typeof defaultExport === 'object' && defaultExport !== moduleObj) {
      console.info('[SessionReplayVideo] ' + source + ' has default export candidate');
      const resolvedDefault = this.extractSurfaceApi(defaultExport as Object, source + '.default');
      if (resolvedDefault) {
        return resolvedDefault;
      }
    }
    const gfxExport = moduleRecord['gfxSurface'];
    if (gfxExport && typeof gfxExport === 'object' && gfxExport !== moduleObj) {
      console.info('[SessionReplayVideo] ' + source + ' has gfxSurface property');
      const resolvedGfx = this.extractSurfaceApi(gfxExport as Object, source + '.gfxSurface');
      if (resolvedGfx) {
        return resolvedGfx;
      }
    }
    const surfaceExport = moduleRecord['Surface'];
    if (surfaceExport && typeof surfaceExport === 'object' && surfaceExport !== moduleObj) {
      console.info('[SessionReplayVideo] ' + source + ' has Surface property');
      const resolvedSurface = this.extractSurfaceApi(surfaceExport as Object, source + '.Surface');
      if (resolvedSurface) {
        return resolvedSurface;
      }
    }
    console.warn('[SessionReplayVideo] ' + source + ' module missing createSurfaceFromId after inspection');
    return null;
  }

  private ensureGfxSurfaceRegistered(): boolean {
    if (this.gfxSurfaceReady) {
      return true;
    }
    try {
      // Check if gfxSurface is already available in globalThis (registered elsewhere)
      const g = (globalThis as GlobalThisWithGfxSurface);
      if (g.gfxSurface) {
        this.gfxSurfaceReady = true;
        console.info('[SessionReplayVideo] gfxSurface API already available');
        return true;
      }

      // Try multiple methods to dynamically load @ohos.graphics.surface
      let gfxSurfaceModule: Object | null = null;

      // Method 0: Try requireNapi (HarmonyOS NAPI loader)
      try {
        const requireNapiFn = g.requireNapi;
        if (!gfxSurfaceModule && requireNapiFn && typeof requireNapiFn === 'function') {
          console.info('[SessionReplayVideo] Attempting to load gfxSurface via requireNapi');
          const rawModule = requireNapiFn('@ohos.graphics.surface') as Object;
          gfxSurfaceModule = this.extractSurfaceApi(rawModule, 'requireNapi');
        }
      } catch (err) {
        console.warn('[SessionReplayVideo] requireNapi load failed: ' + String(err));
      }

      // Method 1: Try direct require (if supported in runtime)
      try {
        const requireFunc = g.require;
        if (!gfxSurfaceModule && requireFunc && typeof requireFunc === 'function') {
          console.info('[SessionReplayVideo] Attempting to load gfxSurface via require');
          const rawModule = requireFunc('@ohos.graphics.surface') as Object;
          gfxSurfaceModule = this.extractSurfaceApi(rawModule, 'require');
        }
      } catch (err) {
        console.warn('[SessionReplayVideo] require load failed: ' + String(err));
      }

      // Method 2: Try accessing via system module loader (if available)
      if (!gfxSurfaceModule) {
        try {
          const systemModule = g.system;
          const loadModule = systemModule?.loadModule;
          if (loadModule && typeof loadModule === 'function') {
            console.info('[SessionReplayVideo] Attempting to load gfxSurface via system.loadModule');
            const rawModule = loadModule('@ohos.graphics.surface') as Object;
            gfxSurfaceModule = this.extractSurfaceApi(rawModule, 'system.loadModule');
          }
        } catch (err) {
          console.warn('[SessionReplayVideo] system.loadModule failed: ' + String(err));
        }
      }

      // Method 3: Check if module is available in module cache (if HarmonyOS supports it)
      if (!gfxSurfaceModule) {
        try {
          const moduleCache = g.__modules__;
          const cacheGetter = moduleCache?.get;
          if (cacheGetter && typeof cacheGetter === 'function') {
            console.info('[SessionReplayVideo] Attempting to load gfxSurface via module cache');
            const cachedModule = cacheGetter('@ohos.graphics.surface');
            if (cachedModule) {
              gfxSurfaceModule = this.extractSurfaceApi(cachedModule as Object, 'moduleCache');
            }
          }
        } catch (err) {
          console.warn('[SessionReplayVideo] module cache load failed: ' + String(err));
        }
      }

      if (gfxSurfaceModule) {
        g.gfxSurface = gfxSurfaceModule;
        this.gfxSurfaceReady = true;
        console.info('[SessionReplayVideo] gfxSurface API registered successfully');
        return true;
      } else {
        const loadHints = `requireNapi=${typeof g.requireNapi}, require=${typeof g.require}, system.loadModule=${typeof g.system?.loadModule}, cacheHasGet=${typeof g.__modules__?.get}`;
        console.warn('[SessionReplayVideo] gfxSurface API not available in globalThis, video encoding will use JPEG fallback. loaders=' + loadHints);
      }
    } catch (err) {
      console.warn('[SessionReplayVideo] gfxSurface API unavailable: ' + String(err));
    }
    return false;
  }

  private tryStartReplay(): void {
    if (!this.replayStartRequested || this.replayStarted) {
      return;
    }
    if (!this.replayServerUrl) {
      console.warn('[SessionReplayVideo] Replay server URL not set, skip start');
      return;
    }
    const ctx = this.abilityContext;
    if (!ctx) {
      if (!this.replayWaitingForUiCtxLogged) {
        console.warn('[SessionReplayVideo] Waiting for UIAbility context to enable video replay');
        this.replayWaitingForUiCtxLogged = true;
      }
      return;
    }
    const canEnableVideo = this.ensureGfxSurfaceRegistered();
    const enableScreenFrames = canEnableVideo;
    if (!canEnableVideo) {
      console.warn('[SessionReplayVideo] gfxSurface unavailable, falling back to raw Flutter frames');
    }
    const startOptions: ReplayStartOptions = {
      context: ctx,
      serverUrl: this.replayServerUrl,
      sessionSampleRate: this.replaySessionSampleRate,
      onErrorSampleRate: this.replayOnErrorSampleRate,
      enableScreenFrames: enableScreenFrames,
    } as ReplayStartOptions;
    if (enableScreenFrames) {
      startOptions.frameIntervalMs = this.replayFrameIntervalMs;
      startOptions.segmentMs = this.replaySegmentMs;
    }
    try {
      console.info('[SessionReplayVideo] Starting Replay with enableScreenFrames=' + String(enableScreenFrames));
      startReplay(startOptions);
      this.replayStarted = true;
      console.info('[SessionReplayVideo] Replay started successfully');
    } catch (err) {
      console.error('[SessionReplayVideo] Failed to start Replay: ' + String(err));
      if (!this.replayStarted) {
        try {
          startReplay({ context: ctx, serverUrl: this.replayServerUrl } as ReplayStartOptions);
          this.replayStarted = true;
          console.info('[SessionReplayVideo] Replay started without screen frames');
        } catch (_) {}
      }
    }
  }

  initNativeSdk(call: MethodCall, result: MethodResult): void {
    try {
      // Derive replay enablement from Flutter's replay config (session/onError sample rates)
      let sessionSampleRate = 0.0;
      let onErrorSampleRate = 0.0;
      try {
        const replayArgs = call.argument('replay') as Object | null;
        if (replayArgs && typeof (replayArgs as Record<string, ESObject>) === 'object') {
          const r = replayArgs  as Record<string, ESObject>;
          const ssr = r.get('sessionSampleRate') as number | undefined;
          const oesr = r.get('onErrorSampleRate') as number | undefined;
          sessionSampleRate = ssr ?? 0;
          onErrorSampleRate = oesr ?? 0;
        }
        this.replayEnabled = (sessionSampleRate > 0) || (onErrorSampleRate > 0);
      } catch (_) {
        this.replayEnabled = false;
        sessionSampleRate = 0.0;
        onErrorSampleRate = 0.0;
      }

      // 读取与 Android 对齐的初始化参数
      const enableAutoSessionTracking = (call.argument('enableAutoSessionTracking') as boolean) ?? true;
      const sessionIntervalMs = (call.argument('autoSessionTrackingIntervalMillis') as number) ?? 30000;
      const sendClientReports = (call.argument('sendClientReports') as boolean) ?? false;
      const recordHttpBreadcrumbs = (call.argument('recordHttpBreadcrumbs') as boolean) ?? true;
      const captureFailedRequests = (call.argument('captureFailedRequests') as boolean) ?? false;
      const connectTimeoutMs = call.argument('connectionTimeoutMillis') as number | null;
      const readTimeoutMs = call.argument('readTimeoutMillis') as number | null;
      this.autoSessionEnabled = enableAutoSessionTracking === true;

      this.pluginDebug = (call.argument('debug') as boolean) === true;
      // 提前设置 BaseContext，便于在 init 阶段配置缓存目录（供 HttpTransport 使用）
      try { SentryOhos.setBaseContext(this.binding!.getApplicationContext()); } catch (_) {}
      this.replayServerUrl = call.argument('dsn') as string | null;
      this.replaySessionSampleRate = sessionSampleRate;
      this.replayOnErrorSampleRate = onErrorSampleRate;
      this.replayStartRequested = this.replayEnabled;
      this.nativeSdkState = 'initializing';
      try {
        SentryOhos.init({
        dsn: call.argument('dsn'),
        debug: this.pluginDebug,
        environment: call.argument('environment'),
        // release content can be replaced with your app version name
        release: call.argument('release') ?? 'com.example.app@1.0.0+1',
        attachStacktrace: call.argument('attachStacktrace'),
        dist: call.argument('dist'),
        maxBreadcrumbs: call.argument('maxBreadcrumbs'),
        errorsSampleRate: 1.0,
        tracesSampleRate: 1.0,
        sdkName: 'sentry-ohos',
        enableReplay: this.replayEnabled,
        enableAnr: call.argument('anrEnabled') ?? true,
        anrReportInDebug: call.argument('anrReportInDebug') ?? false, // 默认false，需要在debug模式下测试时显式设置为true
        anrTickerIntervalMs: call.argument('anrTimeoutIntervalMillis') ?? 5000,
        replayServerUrl: call.argument('dsn'),
        // 会话与客户端报告（与 Android 对齐）
        enableAutoSessionTracking: enableAutoSessionTracking,
        sessionTrackingIntervalMillis: sessionIntervalMs,
        sendClientReports: sendClientReports,
        // HTTP 相关（与 Android 的网络面包屑/失败请求对齐）
        enableHttpBreadcrumbs: recordHttpBreadcrumbs,
        enableHttpTracing: captureFailedRequests,
        httpConnectTimeoutMs: connectTimeoutMs ?? undefined,
        httpReadTimeoutMs: readTimeoutMs ?? undefined,
        });
        this.nativeSdkState = 'initialized';
      } catch (initErr) {
        // init 抛异常时将状态回退为 'uninitialized'，避免状态机卡在 'initializing'
        // 导致 onUnhandledException 的 nativeSdkInitialized 判断始终为 false 而丢失去重能力，
        // 也避免误以为原生侧已准备好而吞掉后续可补偿的异常。
        this.nativeSdkState = 'uninitialized';
        console.error('[Sentry] SentryOhos.init failed: ' + String(initErr));
        throw initErr as Error;
      }
      // 自动会话：启动即开始 session（与 Android Auto Session Tracking 对齐）
      try {
        if (this.autoSessionEnabled) {
          SentryOhos.startSession();
        }
      } catch (_) {}
      // 将初始化前缓存的异常补偿上报
      try {
        if (this.pendingUnhandledErrors.length > 0) {
          const errs = this.pendingUnhandledErrors.splice(0, this.pendingUnhandledErrors.length);
          for (const e of errs) {
            try { Sentry.getHub().captureException(e); } catch (_) {}
          }
        }
      } catch (_) {}
      // 启动 Replay（对齐 Android 原生集成：初始化后即开始），同时保留桥接通知
      this.tryStartReplay();
      try { if (this.replayRecorder) this.replayRecorder.setEnabled(this.replayEnabled); } catch (_) {}
      try { if (this.replayEnabled && this.replayRecorder) this.replayRecorder.startIfHasReplayId(); } catch (_) {}
      result.success(true);
    } catch (err) {
      console.error(`[SentryFlutterPlugin] Failed to initialize Sentry NDK: ${err.message}`);
      result.success(false);
    }
  }

  onAbilityDestroy(): void {
    stopReplay();
    errorManager.off('error', this.errorManagerId);
    try {
      if (this.autoSessionEnabled) {
        SentryOhos.endSession();
      }
    } catch (_) {}
    // 停止 Replay 采集（对齐 Android）
    try {
      if (this.replayEnabled && this.channel != null) {
        try {
          if (this.replayEnabled && this.replayRecorder) this.replayRecorder.stop();
    } catch (_) {}
      }
    } catch (_) {}
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.activity = binding.getAbility();
    try {
      this.lifecycleCallbackId =
        this.applicationContext?.getApplicationContext().on('abilityLifecycle', this) ?? -1;
      console.log('Registered lifecycle callback with id:', this.lifecycleCallbackId);
    } catch (e) {
      console.error('Failed to register lifecycle callback:', JSON.stringify(e));
    }
    try {
      let ctx: common.BaseContext | null = null;
      const ability = this.activity;
      if (ability) {
        // Try to access context property via interface
        const abilityWithCtxProp = ability as UIAbilityWithContext;
        if (abilityWithCtxProp.context) {
          ctx = abilityWithCtxProp.context;
        }
      }
      if (!ctx) {
        try {
          const abilityWithCtx = ability as UIAbilityWithGetContext;
          const maybeCtx = abilityWithCtx?.getContext?.();
          if (maybeCtx) ctx = maybeCtx;
        } catch (_) {}
      }
      if (ctx) {
        this.abilityContext = ctx;
        this.replayWaitingForUiCtxLogged = false;
        try {
          updateReplayContext(ctx);
          console.info('[SessionReplayVideo] UIAbilityContext obtained and updated');
        } catch (err) {
          console.warn('[SessionReplayVideo] Failed to update Replay context: ' + String(err));
        }
        // Ensure gfxSurface is registered before starting replay
        this.ensureGfxSurfaceRegistered();
        this.tryStartReplay();
      } else {
        console.warn('[SessionReplayVideo] Failed to obtain UIAbilityContext from ability');
      }
    } catch (err) {
      console.warn('[SessionReplayVideo] Failed to acquire UIAbility context: ' + String(err));
    }
  }

  onDetachedFromAbility(): void {
    this.activity = null;
    this.abilityContext = null;
    try {
      this.applicationContext?.getApplicationContext().off("abilityLifecycle", this.lifecycleCallbackId);
    } catch (e) {
      console.error('Failed to register lifecycle callback:', JSON.stringify(e));
    }
  }

  getUniqueClassName(): string {
    return "SentryFlutterPlugin"
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.binding = binding;
    this.pluginRegistrationTime = Date.now()
    this.channel = new MethodChannel(binding.getBinaryMessenger(), "sentry_flutter");
    // Prepare replay recorder bridge for OHOS (align Android native bridge)
    try {
      this.replayRecorder = new SentryFlutterReplayRecorder(this.channel);
    } catch (_) {
      this.replayRecorder = null;
    }
    this.replayFrameChannel = new MethodChannel(binding.getBinaryMessenger(), SentryFlutterPlugin.REPLAY_FRAME_CHANNEL);
    this.replayFrameChannel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.onReplayFrameChannelCall(call, result);
      }
    });
    this.applicationContext = binding.getApplicationContext()
    this.abilityContextProvider = this.applicationContext;
    this.channel.setMethodCallHandler(this)
    // 尽早注册全局未捕获异常处理器：在 SDK init 之前也能先缓存异常。
    // 生命周期说明：observer 通过闭包捕获 `pluginSelf`（= 当前 Plugin 实例）访问
    // `nativeSdkState`，其生命周期与 Plugin 实例绑定——已通过 `this.errorManagerId`
    // 在 `onAbilityDestroy()` 中调用 `errorManager.off('error', this.errorManagerId)`
    // 显式反注册，确保 Plugin 销毁后 observer 不再被触发、也不会保留对已释放实例的引用。
    // ArkTS 单线程模型下 `nativeSdkState` 的读写无需额外同步原语。
    const pluginSelf = this;
    const observer: errorManager.ErrorObserver = {
      onUnhandledException(errorMsg: string) {
        try {
          // SentryOhos.init() 完成后 installGlobalErrorHandler 已激活，
          // 它会通过 onerror 以更高质量（含堆栈帧、mechanism、截图）捕获同一异常。
          // 此处跳过以避免重复上报。
          if (pluginSelf.nativeSdkInitialized) {
            return;
          }
          const hub = Sentry.getHubIfAvailable();
          if (hub) {
            hub.captureException(new Error(String(errorMsg)));
          } else {
            console.warn('[Sentry] onUnhandledException received before SDK initialization: ' + String(errorMsg));
          }
        } catch (err) {
          console.warn('[Sentry] onUnhandledException handling failed: ' + String(err));
      }
    }
    };
    this.errorManagerId = errorManager.on('error', observer);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null)
    }
    if (this.replayFrameChannel != null) {
      this.replayFrameChannel.setMethodCallHandler(null);
      this.replayFrameChannel = null;
    }
  }

  onAbilityForeground(ability: UIAbility): void {
    SentryOhos.setForeground(true);
    onAppForeground();
    try {
      if (this.autoSessionEnabled) {
        SentryOhos.startSession();
      }
    } catch (_) {}
    // 恢复 Replay（对齐 Android）
    try { if (this.replayEnabled) resumeReplay(); } catch (_) {}
    try {
      const ctx = this.binding?.getApplicationContext() as common.BaseContext;
      if (ctx) { try { updateReplayContext(ctx); } catch (_) {} }
    } catch (_) {}
  }

  async onAbilityBackground(ability: UIAbility): Promise<void> {
    SentryOhos.setForeground(false);
    await onAppBackground();
    try {
      if (this.autoSessionEnabled) {
        SentryOhos.endSession();
      }
    } catch (_) {}
    // 暂停 Replay 并触发一次上传（对齐 Android）
    try { if (this.replayEnabled) pauseReplay(); } catch (_) {}
    try {
      if (this.replayEnabled) {
        const ctx = this.binding?.getApplicationContext() as common.BaseContext;
        const serverUrl: string = (Sentry.getHub().getOptions().dsn as string) || '';
        try { await uploadReplay(serverUrl, ctx); } catch (_) {}
      }
    } catch (_) {}
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    console.log(`onMethodCall method = ${call.method}`);
    if (call.method == "initNativeSdk") {
      this.initNativeSdk(call, result)
    } else if (call.method == "captureEnvelope") {
      this.captureEnvelope(call, result)
    } else if (call.method == "captureEnvelopeFromPath") {
      this.captureEnvelopeFromPath(call, result)
    } else if (call.method == "loadImageList") {
      this.loadImageList(call, result)
    } else if (call.method == "closeNativeSdk") {
      this.closeNativeSdk(result)
    } else if (call.method == "fetchNativeAppStart") {
      this.fetchNativeAppStart(result)
    } else if (call.method == "setContexts") {
      this.setContexts(call.argument("key"), call.argument("value"), result)
    } else if (call.method == "removeContexts") {
      this.removeContexts(call.argument("key"), result)
    } else if (call.method == "setUser") {
      this.setUser(call.argument("user"), result)
    } else if (call.method == "addBreadcrumb") {
      this.addBreadcrumb(call.argument("breadcrumb"), result);
    } else if (call.method == "clearBreadcrumbs") {
      this.clearBreadcrumbs(result);
    } else if (call.method == "setExtra") {
      this.setExtra(call.argument("key"), call.argument("value"), result)
    } else if (call.method == "removeExtra") {
      this.removeExtra(call.argument("key"), result)
    } else if (call.method == "setTag") {
      this.setTag(call.argument("key"), call.argument("value"), result)
    } else if (call.method == "removeTag") {
      this.removeTag(call.argument("key"), result)
    } else if (call.method == "loadContexts") {
      this.loadContexts(result)
    } else if (call.method == "displayRefreshRate") {
      this.displayRefreshRate(result)
    } else if (call.method == "nativeCrash") {
      this.nativeCrash()
    } else if (call.method == "setReplayConfig") {
      this.setReplayConfig(call, result)
    } else if (call.method == "setLastErrorEventId") {
      this.setLastErrorEventId(call, result)
    } else if (call.method == "captureReplay") {
      this.captureReplay(result)
    } else if (call.method == "get_replay_id") {
      this.getReplayIdForFlutter(result)
    } else if (call.method == "getPlatformVersion") {
      result.success("OpenHarmony ^ ^ ")
    } else {
      result.notImplemented()
    }
  }

  private getReplayIdForFlutter(result: MethodResult): void {
    try {
      const rid = getReplayId();
      if (typeof rid === 'string' && rid.length > 0) {
        result.success(rid);
        return;
      }
      result.success("");
    } catch (_) {
      result.success("");
    }
  }

  private onReplayFrameChannelCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'pushFrame') {
      this.handlePushFrame(call, result);
      return;
    }
    if (call.method === 'pushFrameBatch') {
      this.handlePushFrameBatch(call, result);
      return;
    }
    if (call.method === 'setScrollingState') {
      this.handleSetScrollingState(call, result);
      return;
    }
    if (call.method === 'startNativeScreenshot') {
      this.handleStartNativeScreenshot(call, result);
      return;
    }
    if (call.method === 'stopNativeScreenshot') {
      this.handleStopNativeScreenshot(call, result);
      return;
    }
    result.notImplemented();
  }

  private handlePushFrame(call: MethodCall, result: MethodResult): void {
    const payload: Record<string, Object | null> = {} as Record<string, Object | null>;
    payload['pixels'] = call.argument('pixels');
    payload['width'] = call.argument('width');
    payload['height'] = call.argument('height');
    payload['stride'] = call.argument('stride');
    payload['timestamp'] = call.argument('timestamp');
    this.enqueueFrameForNative(payload);
    result.success(null);
  }

  private handlePushFrameBatch(call: MethodCall, result: MethodResult): void {
    const batchStart = Date.now();
    const frames = call.argument('frames') as Object | null;
    if (!(frames instanceof Array)) {
      result.success(null);
      return;
    }
    for (let i = 0; i < frames.length; i++) {
      const candidate = frames[i] as Object | null;
      const payload = this.materializeBatchFrame(candidate);
      if (payload) {
        this.enqueueFrameForNative(payload);
      } else {
        try {
          console.warn('[REPLAY_TAG SessionReplayBridge] materializeBatchFrame failed index=' + String(i));
        } catch (_) {}
      }
    }
    const batchTime = Date.now() - batchStart;
    if (frames.length > 0 && batchTime > 30) {
      try {
        console.debug(`[PERF] SessionReplayBridge enqueue batch count=${frames.length} time=${batchTime}ms queue=${this.frameQueue.length}`);
      } catch (_) {}
    }
    result.success(null);
  }

  private materializeBatchFrame(source: Object | null | undefined): Record<string, Object | null> | undefined {
    if (!source) {
      return undefined;
    }
    const payload: Record<string, Object | null> = {} as Record<string, Object | null>;
    payload['pixels'] = this.extractFrameField(source, 'pixels') ?? null;
    payload['width'] = this.extractFrameField(source, 'width') ?? null;
    payload['height'] = this.extractFrameField(source, 'height') ?? null;
    payload['stride'] = this.extractFrameField(source, 'stride') ?? null;
    payload['timestamp'] = this.extractFrameField(source, 'timestamp') ?? null;
    return payload;
  }

  private extractFrameField(source: Object, key: string): Object | null | undefined {
    try {
      if (source instanceof Map) {
        const mapValue = source as Map<string, Object | null | undefined>;
        if (mapValue.has(key)) {
          return mapValue.get(key);
        }
        return undefined;
      }
    } catch (_) {}
    const record = source as Record<string, Object | null | undefined>;
    if (this.recordHasKey(record, key)) {
      return record[key];
    }
    return undefined;
  }

  private recordHasKey(record: Record<string, Object | null | undefined>, key: string): boolean {
    const keys = Object.getOwnPropertyNames(record);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] === key) {
        return true;
      }
    }
    return false;
  }

  private flutterFrameIgnoredLogged: boolean = false;

  private enqueueFrameForNative(payload: Record<string, Object | null | undefined>): void {
    if (!(payload instanceof Object)) {
        return;
      }
    // Optimization: If native replay (screen capture) is running, ignore frames from Flutter
    // to avoid double-capture overhead (both Native loop and Flutter channel pushing frames).
    // The Native capture loop in ReplayController is preferred as it captures the whole screen.
    if (this.replayStarted) {
      if (!this.flutterFrameIgnoredLogged) {
        this.flutterFrameIgnoredLogged = true;
        try {
          console.info('[SentryFlutterPlugin] Native replay is active, ignoring Flutter frames to prevent double-capture');
        } catch (_) {}
      }
      return;
    }

    // Always enqueue frames, even during scrolling (for later processing)
    this.frameQueue.push(payload);
    if (this.frameQueue.length > this.maxQueuedFrames) {
      this.frameQueue.shift(); // Drop oldest if queue is full
    }
    // Only start processing if not scrolling and not already processing
    if (!this.isScrolling && !this.encodingPaused && !this.queueProcessing) {
      this.queueProcessing = true;
      setTimeout(() => this.drainFrameQueue(), this.queueDrainDelayMs);
    }
  }

  private drainFrameQueue(): void {
    // Skip processing if scrolling or encoding is paused
    if (this.isScrolling || this.encodingPaused) {
      this.queueProcessing = false;
      // Schedule retry after a delay when scrolling ends
      if (this.frameQueue.length > 0) {
        setTimeout(() => {
          if (!this.isScrolling && !this.encodingPaused && !this.queueProcessing) {
            this.queueProcessing = true;
            this.drainFrameQueue();
          }
        }, this.queueDrainDelayMs * 2);
      }
        return;
      }
    if (this.frameQueue.length === 0) {
      this.queueProcessing = false;
        return;
      }
    const frame = this.frameQueue.shift();
    if (frame) {
      const ok = this.pushFramePayload(frame as Record<string, Object | null | undefined>);
      if (!ok) {
        try {
          console.warn('[REPLAY_TAG SessionReplayBridge] frame queue drop: pushFramePayload returned false');
        } catch (_) {}
      } else {
        try {
          console.debug(`[REPLAY_TAG SessionReplayBridge] frame queue processed=1 remaining=${this.frameQueue.length}`);
        } catch (_) {}
      }
    }
    // Continue processing if more frames available and not scrolling
    if (this.frameQueue.length > 0 && !this.isScrolling && !this.encodingPaused) {
      setTimeout(() => this.drainFrameQueue(), this.queueDrainDelayMs);
    } else {
      this.queueProcessing = false;
    }
  }

  private handleSetScrollingState(call: MethodCall, result: MethodResult): void {
    const isScrolling = call.argument('isScrolling') as boolean | null | undefined;
    if (typeof isScrolling === 'boolean') {
      this.isScrolling = isScrolling;
      // Don't pause encoding during scrolling to match Android behavior
      // 通知 ReplayController 更新滑动状态 (Optional, keeping it might be useful for other logic but shouldn't pause)
      try {
        setReplayScrollingState(isScrolling);
      } catch (_) {}

      if (isScrolling) {
        // Don't clear queue during scrolling
        try {
          console.debug(`[PERF] SessionReplayBridge scrolling started (no-op)`);
        } catch (_) {}
      } else {
        try {
          console.debug(`[PERF] SessionReplayBridge scrolling ended (no-op)`);
        } catch (_) {}
        // 立即尝试处理队列，而不是延迟
        if (!this.isScrolling && !this.encodingPaused && this.frameQueue.length > 0 && !this.queueProcessing) {
            this.queueProcessing = true;
            this.drainFrameQueue();
        }
      }
      result.success(null);
    } else {
      result.error('InvalidArgument', 'isScrolling must be a boolean', null);
    }
  }

  private handleStartNativeScreenshot(call: MethodCall, result: MethodResult): void {
    try {
      const frameInterval = call.argument('frameInterval') as number | null | undefined;
      const intervalMs = (typeof frameInterval === 'number' && frameInterval > 0) ? frameInterval : 1000;
      const ctx = this.binding?.getApplicationContext() as common.BaseContext;
      if (!ctx) {
        result.error('NoContext', 'Application context not available', null);
        return;
      }
      // 启动原生截图录制
      startReplay({
        context: ctx,
        serverUrl: this.replayServerUrl,
        enableScreenFrames: true,
        frameIntervalMs: intervalMs,
        sessionSampleRate: 1.0,
        onErrorSampleRate: 1.0,
      } as ReplayStartOptions);
      this.replayStarted = true;
      try {
        console.info(`[PERF] SessionReplayBridge native screenshot started, interval=${intervalMs}ms`);
      } catch (_) {}
      result.success(null);
    } catch (error) {
      try {
        console.error('[PERF] SessionReplayBridge failed to start native screenshot: ' + String(error));
      } catch (_) {}
      result.error('StartFailed', String(error), null);
    }
  }

  private handleStopNativeScreenshot(call: MethodCall, result: MethodResult): void {
    try {
      stopReplay();
      this.replayStarted = false;
      try {
        console.info('[PERF] SessionReplayBridge native screenshot stopped');
      } catch (_) {}
      result.success(null);
    } catch (error) {
      try {
        console.error('[PERF] SessionReplayBridge failed to stop native screenshot: ' + String(error));
      } catch (_) {}
      result.error('StopFailed', String(error), null);
    }
  }

  private pushFramePayload(payload: Record<string, Object | null | undefined>): boolean {
    const perfStart = Date.now();
    try {
      const normalizeStart = Date.now();
      const pixelsSource = payload['pixels'] as Object | null | undefined;
      const pixels = this.normalizeFramePixels(pixelsSource ?? null);
      const normalizeTime = Date.now() - normalizeStart;
      if (!pixels) {
        try {
          console.warn('[REPLAY_TAG SessionReplayBridge] normalizeFramePixels failed for type=' + this.describePixelSource(pixelsSource));
        } catch (_) {}
        return false;
      }
      const widthCandidate = payload['width'];
      const heightCandidate = payload['height'];
      if (typeof widthCandidate !== 'number' || typeof heightCandidate !== 'number') {
        try {
          console.warn('[REPLAY_TAG SessionReplayBridge] invalid frame size: width=' + String(widthCandidate) + ' height=' + String(heightCandidate));
        } catch (_) {}
        return false;
      }
      const width = Math.floor(widthCandidate as number);
      const height = Math.floor(heightCandidate as number);
      if (!(width > 0 && height > 0)) {
        try {
          console.warn('[REPLAY_TAG SessionReplayBridge] non-positive frame size: ' + String(width) + 'x' + String(height));
        } catch (_) {}
        return false;
      }

      let stride = width * 4;
      const strideCandidate = payload['stride'];
      if (typeof strideCandidate === 'number' && strideCandidate > 0) {
        stride = Math.floor(strideCandidate as number);
      }

      let timestamp = Date.now();
      const timestampCandidate = payload['timestamp'];
      if (typeof timestampCandidate === 'number' && timestampCandidate > 0) {
        const microsecondThreshold = 100000000000000;
        let normalized = Math.floor(timestampCandidate as number);
        let converted = false;
        if (normalized > microsecondThreshold) {
          normalized = Math.floor(normalized / 1000);
          converted = true;
        }
        if (normalized > 0) {
          timestamp = normalized;
          if (converted && !this.timestampNormalizationLogged) {
            this.timestampNormalizationLogged = true;
            try {
              console.debug('[REPLAY_TAG SessionReplayBridge] normalized microsecond timestamp to milliseconds');
            } catch (_) {}
          }
        }
      }

      const cloneStart = Date.now();
      const buffer = this.clonePixelsToBuffer(pixels);
      const cloneTime = Date.now() - cloneStart;

      this.dumpFlutterFrameOnce(pixels, buffer, width, height, stride, timestamp);

      const pushStart = Date.now();
      pushFlutterFrame(buffer, width, height, stride, timestamp);
      const pushTime = Date.now() - pushStart;

      const totalTime = Date.now() - perfStart;
      if (totalTime > 30 || normalizeTime > 20 || cloneTime > 15 || pushTime > 20) {
        console.debug(`[PERF] SessionReplayBridge pushFramePayload: size=${width}x${height} normalize=${normalizeTime}ms clone=${cloneTime}ms push=${pushTime}ms total=${totalTime}ms`);
      }
      return true;
    } catch (err) {
      const message = (err instanceof Error && typeof err.message === 'string') ? err.message : String(err);
      console.error('[REPLAY_TAG SessionReplayBridge] pushFrame failed: ' + message);
      return false;
    }
  }

  private normalizeFramePixels(source: Object | null): Uint8Array | undefined {
    if (!source) {
      return undefined;
    }
    if (source instanceof Uint8Array) {
      return this.cloneUint8Array(source as Uint8Array);
    }
    if (source instanceof ArrayBuffer) {
      return new Uint8Array(source as ArrayBuffer);
    }
    // Dart isolate/MethodChannel 可能传递 Int8Array/Int32Array 等其它 TypedArray
    if (source instanceof Int8Array ||
        source instanceof Uint8ClampedArray ||
        source instanceof Int16Array ||
        source instanceof Uint16Array ||
        source instanceof Int32Array ||
        source instanceof Uint32Array ||
        source instanceof Float32Array ||
        source instanceof Float64Array ||
        source instanceof BigInt64Array ||
        source instanceof BigUint64Array ||
        source instanceof DataView) {
      const typed = source as ArrayBufferView;
      return this.cloneUint8Array(new Uint8Array(typed.buffer.slice(0)));
    }
    if (Array.isArray(source)) {
      const arr = source as Array<number | bigint>;
      const buffer = new Uint8Array(arr.length);
      for (let i = 0; i < arr.length; i++) {
        const value = arr[i];
        if (typeof value === 'number') {
          buffer[i] = value & 0xFF;
        } else if (typeof value === 'bigint') {
          buffer[i] = Number(value & BigInt(0xFF));
        } else {
          buffer[i] = 0;
        }
      }
      return buffer;
    }
    return undefined;
  }

  private cloneUint8Array(src: Uint8Array): Uint8Array {
    // Prefer the native slice implementation: it is backed by C++ and avoids
    // copying byte-by-byte in ArkTS/JS, which is a noticeable hotspot while
    // replay recording runs on HarmonyOS devices.
    if (typeof src.slice === 'function') {
      try {
        return src.slice(0);
      } catch (_) {
        // fall back to manual copy
      }
    }
    const copy = new Uint8Array(src.byteLength);
    copy.set(src);
    return copy;
  }

  private describePixelSource(value: Object | null | undefined): string {
    if (value === null) {
      return 'null';
    }
    if (value === undefined) {
      return 'undefined';
    }
    if (value instanceof Uint8Array) return 'Uint8Array(' + String(value.length) + ')';
    if (value instanceof ArrayBuffer) return 'ArrayBuffer(' + String((value as ArrayBuffer).byteLength) + ')';
    if (value instanceof Int8Array) return 'Int8Array(' + String(value.length) + ')';
    if (value instanceof Uint8ClampedArray) return 'Uint8ClampedArray(' + String(value.length) + ')';
    if (value instanceof Int16Array) return 'Int16Array(' + String(value.length) + ')';
    if (value instanceof Uint16Array) return 'Uint16Array(' + String(value.length) + ')';
    if (value instanceof Int32Array) return 'Int32Array(' + String(value.length) + ')';
    if (value instanceof Uint32Array) return 'Uint32Array(' + String(value.length) + ')';
    if (value instanceof Float32Array) return 'Float32Array(' + String(value.length) + ')';
    if (value instanceof Float64Array) return 'Float64Array(' + String(value.length) + ')';
    if (value instanceof BigInt64Array) return 'BigInt64Array(' + String(value.length) + ')';
    if (value instanceof BigUint64Array) return 'BigUint64Array(' + String(value.length) + ')';
    if (value instanceof DataView) return 'DataView(' + String((value as DataView).byteLength) + ')';
    if (Array.isArray(value)) return 'Array(' + String(value.length) + ')';
    return (value as Object).constructor?.name ?? typeof value;
  }

  private clonePixelsToBuffer(pixels: Uint8Array): ArrayBuffer {
    const byteOffset = pixels.byteOffset ?? 0;
    const byteLength = pixels.byteLength ?? pixels.length;
    try {
      // slice() on the underlying ArrayBuffer is implemented natively and is
      // significantly faster than copying one byte at a time in ArkTS.
      const sourceBuffer = pixels.buffer;
      if (typeof sourceBuffer.slice === 'function') {
        return sourceBuffer.slice(byteOffset, byteOffset + byteLength);
      }
    } catch (_) {
      // fallback to manual copy below
    }
    const copy = new Uint8Array(byteLength);
    copy.set(pixels);
    return copy.buffer as ArrayBuffer;
  }

  private flutterFrameDumped: boolean = false;
  private timestampNormalizationLogged: boolean = false;

  private dumpFlutterFrameOnce(pixels: Uint8Array, buffer: ArrayBuffer, width: number, height: number, stride: number, timestamp: number): void {
    if (this.flutterFrameDumped) {
      return;
    }
    try {
      if (!this.abilityContextProvider) {
        return;
      }
      const baseDir = this.extractFilesDir(this.abilityContextProvider);
      if (!baseDir) {
        return;
      }
      const prefix = `${baseDir}/raw_flutter_frame_${timestamp}`;
      const rgbaPath = `${prefix}.rgba`;
      const jsonPath = `${prefix}.json`;
      try {
        const file = fs.openSync(rgbaPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fileio.writeSync(file.fd, buffer);
        fs.closeSync(file.fd);
      } catch (err) {
        console.warn('[REPLAY_TAG SessionReplayBridge] dump rgba failed: ' + String(err));
      }
      const meta = new FlutterFrameMeta(width, height, stride, timestamp, pixels.length);
      try {
        const jsonData = this.encodeUtf8(JSON.stringify(meta));
        const jfile = fs.openSync(jsonPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fileio.writeSync(jfile.fd, jsonData.buffer);
        fs.closeSync(jfile.fd);
      } catch (err) {
        console.warn('[REPLAY_TAG SessionReplayBridge] dump meta failed: ' + String(err));
      }
      this.flutterFrameDumped = true;
    } catch (_) {}
  }

  private extractFilesDir(ctx: common.Context): string | undefined {
    const filesDirValue = this.getFilesDirFromContext(ctx);
    if (filesDirValue) {
      return filesDirValue;
    }
    const cacheDirValue = this.getCacheDirFromContext(ctx);
    if (cacheDirValue) {
      return cacheDirValue;
    }
    return undefined;
  }

  private getFilesDirFromContext(ctx: common.Context): string | undefined {
    const maybe = ctx as Object;
    const provider = maybe as FileDirProvider;
    const value = provider.filesDir;
    return (typeof value === 'string' && value.length > 0) ? value : undefined;
  }

  private getCacheDirFromContext(ctx: common.Context): string | undefined {
    const maybe = ctx as Object;
    const provider = maybe as FileDirProvider;
    const value = provider.cacheDir;
    return (typeof value === 'string' && value.length > 0) ? value : undefined;
  }

  private encodeUtf8(text: string): Uint8Array {
    const length = text.length;
    const bytes: Array<number> = [];
    for (let i = 0; i < length; i++) {
      let code = text.charCodeAt(i);
      if (code >= 0xD800 && code <= 0xDBFF) {
        // High surrogate, check for following low surrogate
        if (i + 1 < length) {
          const next = text.charCodeAt(i + 1);
          if (next >= 0xDC00 && next <= 0xDFFF) {
            // Combine to code point
            code = ((code - 0xD800) << 10) + (next - 0xDC00) + 0x10000;
            i++;
          }
        }
      }

      if (code < 0x80) {
        bytes.push(code);
      } else if (code < 0x800) {
        bytes.push(0xc0 | (code >> 6));
        bytes.push(0x80 | (code & 0x3f));
      } else if (code < 0x10000) {
        bytes.push(0xe0 | (code >> 12));
        bytes.push(0x80 | ((code >> 6) & 0x3f));
        bytes.push(0x80 | (code & 0x3f));
      } else {
        bytes.push(0xf0 | (code >> 18));
        bytes.push(0x80 | ((code >> 12) & 0x3f));
        bytes.push(0x80 | ((code >> 6) & 0x3f));
        bytes.push(0x80 | (code & 0x3f));
      }
    }
    const out = new Uint8Array(bytes.length);
    for (let i = 0; i < bytes.length; i++) {
      out[i] = bytes[i];
    }
    return out;
  }

  private decodeUtf8(bytes: Uint8Array, start: number, end: number): string {
    let i = start;
    let out = '';
    while (i < end) {
      let c = bytes[i++];
      if (c < 128) {
        out += String.fromCharCode(c);
      } else if (c > 191 && c < 224) {
        if (i >= end) break;
        let c2 = bytes[i++];
        out += String.fromCharCode(((c & 31) << 6) | (c2 & 63));
      } else if (c > 223 && c < 240) {
        if (i + 1 >= end) break;
        let c2 = bytes[i++];
        let c3 = bytes[i++];
        out += String.fromCharCode(((c & 15) << 12) | ((c2 & 63) << 6) | (c3 & 63));
      } else if (c > 239 && c < 248) {
        if (i + 2 >= end) break;
        let c2 = bytes[i++];
        let c3 = bytes[i++];
        let c4 = bytes[i++];
        let cp = ((c & 7) << 18) | ((c2 & 63) << 12) | ((c3 & 63) << 6) | (c4 & 63);
        cp -= 0x10000;
        out += String.fromCharCode(0xD800 + (cp >> 10));
        out += String.fromCharCode(0xDC00 + (cp & 0x3FF));
      }
    }
    return out;
  }

  async captureEnvelope(call: MethodCall, result: MethodResult): Promise<void> {
    console.info('[SentryTrace] SentryFlutterPlugin: captureEnvelope called');
    type CaptureEnvelopeListArgs = [Uint8Array | ArrayBuffer | number[], boolean];
    try {
      // Flutter 层按数组传参：[bytes, containsUnhandled]
      const listArgs = call.args as CaptureEnvelopeListArgs;
      if (!listArgs || listArgs.length < 2) {
        // Align with Android error code and message
        result.error("3", "Envelope is null or empty", null);
        return;
      }
      const raw = listArgs[0];
      const containsUnhandled = !!listArgs[1];

      let data: Uint8Array;
      if (raw instanceof Uint8Array) {
        data = raw;
      } else if (raw instanceof ArrayBuffer) {
        data = new Uint8Array(raw);
      } else {
        data = new Uint8Array(raw as number[]);
      }

      if (data.length === 0) {
        result.error("3", "Envelope is null or empty", null);
        return;
      }

      // Debug snapshot: dump envelope head and first 32 bytes of the first PNG attachment (only when debug=true)
      if (this.pluginDebug) try {
        const dumpDir: string = '/data/storage/el2/base/haps/entry/files/sentry';
        try {
          const st = fs.statSync(dumpDir);
          if (!st.isDirectory()) { fs.mkdirSync(dumpDir); console.info('[SentryDump] mkdir dumpDir (not dir) ' + dumpDir); }
        } catch (e) {
          try { fs.mkdirSync(dumpDir); console.info('[SentryDump] mkdir dumpDir ' + dumpDir); } catch (e2) { console.error('[SentryDump] mkdir failed ' + (e2?.message || '')); }
        }
        const ts = Date.now();

        const toHex = (u8: Uint8Array): string => {
          const hex: Array<string> = [];
          const n = Math.min(32, u8.byteLength);
          for (let i = 0; i < n; i++) {
            const v = u8[i] & 0xFF;
            const h = v.toString(16).toUpperCase();
            hex.push((h.length === 1 ? '0' + h : h));
          }
          return hex.join(' ');
        };

        const readLineEnd = (buf: Uint8Array, start: number): number => {
          const len = buf.byteLength;
          let i = start;
          while (i < len) {
            if (buf[i] === 0x0A) return i; // LF
            i++;
          }
          return -1;
        };

        const decodeAscii = (buf: Uint8Array, s: number, e: number): string => {
          // decode [s, e) bytes as ASCII/UTF-8-safe for JSON headers
          let out = '';
          for (let i = s; i < e; i++) {
            out += String.fromCharCode(buf[i] & 0xFF);
          }
          return out;
        };

        const envHeadHex = toHex(data.subarray(0, Math.min(32, data.length)));
        console.info('[SentryDump] envelope bytes=' + String(data.length) + ' head32.len=' + String(envHeadHex.length));

        // Try to locate the first image/png attachment body and dump its first 32 bytes
        let pngHeadHex: string = '';
        try {
          let pos = 0;
          // 1) envelope header line
          let lineEnd = readLineEnd(data, pos);
          if (lineEnd > pos) {
            pos = lineEnd + 1;
          }
          // Iterate items
          while (pos >= 0 && pos < data.byteLength) {
            // item header line
            const hdrEnd = readLineEnd(data, pos);
            if (hdrEnd < 0) break;
            const hdrStr = decodeAscii(data, pos, hdrEnd);
            pos = hdrEnd + 1;
            let item: Record<string, ESObject> | null = null;
            try { item = JSON.parse(hdrStr) as Record<string, ESObject>; } catch (_) { break; }
            if (!item) break;
            const typeVal = (item as Record<string, ESObject>)['type'] as string | undefined;
            let lengthVal = (item as Record<string, ESObject>)['length'] as number | undefined;
            let contentType = ((item as Record<string, ESObject>)['content_type'] as string | undefined) || ((item as Record<string, ESObject>)['contentType'] as string | undefined);
            // Attachments may put filename/content_type in next meta line; handle both styles
            if (typeVal === 'attachment' && (!contentType || contentType.length === 0)) {
              const metaEnd = readLineEnd(data, pos);
              if (metaEnd > pos) {
                const metaStr = decodeAscii(data, pos, metaEnd);
                pos = metaEnd + 1;
                try {
                  const metaObj = JSON.parse(metaStr) as Record<string, ESObject>;
                  if (!contentType) contentType = (metaObj['content_type'] as string) || (metaObj['contentType'] as string);
                  if (lengthVal === undefined) lengthVal = metaObj['length'] as number | undefined;
                } catch (_) {
                  // meta not JSON, treat as payload start
                }
              }
            }
            // Determine payload start and skip logic
            const len = typeof lengthVal === 'number' && lengthVal > 0 ? Math.floor(lengthVal) : 0;
            if (typeVal === 'attachment' && contentType === 'image/png') {
              const start = pos;
              const slice = data.subarray(start, Math.min(start + 32, data.byteLength));
              pngHeadHex = toHex(slice);
              // Do not advance pos further; dump only
              break;
            }
            // Skip payload (and trailing LF) for non-target items
            pos = pos + len;
            if (pos < data.byteLength && data[pos] === 0x0A) pos += 1;
          }
        } catch (e) { console.error('[SentryDump] parse envelope failed ' + (e?.message || '')); }

        const name = `${dumpDir}/cap_env_head_${ts}.txt`;
        try {
          const lines: Array<string> = [];
          lines.push(`envelope_first32: ${envHeadHex}`);
          lines.push(`png_first32: ${pngHeadHex || 'not_found'}`);
          const content = lines.join('\n');
          // create if not exists
          const O_CREAT = 0o100;
          // truncate
          const O_TRUNC = 0o1000;
          // write only
          const O_WRONLY = 0o1;
          console.info('[SentryDump] open ' + name);
          const fd = fileio.openSync(name, O_CREAT | O_TRUNC | O_WRONLY, 0o666);
          const written = fileio.writeSync(fd, content);
          console.info('[SentryDump] written=' + String(typeof written === 'number' ? written : 0));
          try { fileio.closeSync(fd); } catch (e3) { console.error('[SentryDump] close failed ' + (e3?.message || '')); }
        } catch (e) {
          console.error('[SentryDump] write failed ' + (e?.message || ''));
        }
      } catch (_) {}

      try {
        const toSend = this.enableEnvelopeInject ? this.injectReplayIntoEnvelope(data) : data;
        // 1) 先通过 OHOS SDK 追加 session item 并落盘（与 Android 行为一致）
        InternalSentrySdk.captureEnvelopeBytes(toSend, containsUnhandled);
      } catch (_) {
        result.error("2", "Failed to capture envelope", null);
        return;
      }
      result.success("");
    } catch (err) {
      result.error("2", "Failed to capture envelope", null);
    }
  }

  private formatUuid(id: string): string {
    if (typeof id === 'string' && id.length === 32) {
       return id.substring(0, 8) + '-' + id.substring(8, 12) + '-' + id.substring(12, 16) + '-' + id.substring(16, 20) + '-' + id.substring(20);
    }
    return id;
  }

  // 将原始 envelope 二进制中 type=event 的条目 payload 注入 tags.replayId 与 contexts.replay
  private injectReplayIntoEnvelope(src: Uint8Array): Uint8Array {
    try {
      const ridRaw = getReplayId();
      // Use ridRaw directly to match the ID sent by ReplayController
      if (typeof ridRaw !== 'string' || ridRaw.length === 0) return src;

      // Format as UUID (with hyphens) for Sentry linking compatibility
      const rid = this.formatUuid(ridRaw);

      const LF = 0x0A;
      const parts: Array<Uint8Array> = [];

      const findLf = (buf: Uint8Array, s: number): number => {
        for (let i = s; i < buf.length; i++) { if (buf[i] === LF) return i; }
        return -1;
      };
      let pos = 0;
      // 1. Modify Envelope Header (First Line)
      const envEnd = findLf(src, pos);
      if (envEnd < 0) return src;

      try {
        const envHeaderBytes = src.subarray(0, envEnd);
        // Use decodeUtf8 to safely handle multi-byte characters
        const envHeaderStr = this.decodeUtf8(envHeaderBytes, 0, envHeaderBytes.length);
        const envHeader = JSON.parse(envHeaderStr) as Record<string, ESObject>;

        // Inject replay_id into trace context in header (Crucial for Sentry linking)
        const traceObj = (envHeader['trace'] as Record<string, ESObject>) || ({} as Record<string, ESObject>);
        traceObj['replay_id'] = rid as ESObject;
        envHeader['trace'] = traceObj as ESObject;

        const newEnvHeaderStr = JSON.stringify(envHeader);
        parts.push(this.encodeUtf8(newEnvHeaderStr));
        parts.push(new Uint8Array([LF]));
        try { console.info('[SentryFlutterPlugin] Injected replay_id=' + rid + ' into envelope header'); } catch (_) {}
      } catch (e) {
        // Fallback: use original header if parsing fails
        try { console.warn('[SentryFlutterPlugin] Failed to inject replay_id into envelope header: ' + e); } catch (_) {}
        parts.push(src.subarray(0, envEnd + 1));
      }

      pos = envEnd + 1;
      let injected = false;
      while (pos >= 0 && pos < src.length) {
        const hdrStart = pos;
        const hdrEnd = findLf(src, pos); if (hdrEnd < 0) break;
        // Use correct UTF-8 decoding
        const hdrStr = this.decodeUtf8(src, pos, hdrEnd);
        const hdrObj = JSON.parse(hdrStr) as Record<string, ESObject>;
        pos = hdrEnd + 1;
        const typeVal = (hdrObj['type'] as string) || '';
        const lenVal = hdrObj['length'] as number;
        const hasLen = typeof lenVal === 'number' && lenVal >= 0;
        const payloadStart = pos;
        const payloadEnd = hasLen ? (payloadStart + lenVal) : payloadStart;
        if (typeVal === 'event' && hasLen && payloadEnd <= src.length) {
          // 读取事件 JSON
          const evBytes = src.subarray(payloadStart, payloadEnd);
          // Use correct UTF-8 decoding
          const evStr = this.decodeUtf8(evBytes, 0, evBytes.length);
          let evObj = JSON.parse(evStr) as Record<string, ESObject>;
          const eventIdCandidate = evObj['event_id'] as string | undefined;
          const levelCandidate = evObj['level'] as string | undefined;
          const levelLower = (levelCandidate && typeof levelCandidate === 'string') ? levelCandidate.toLowerCase() : '';
          let hasException = false;
          const exceptionCandidateRaw: ESObject | undefined = evObj['exception'] as ESObject | undefined;
          if (exceptionCandidateRaw && typeof exceptionCandidateRaw === 'object') {
            class ExceptionRecordWrapper {
              raw: Record<string, ESObject>;
              constructor(raw: Record<string, ESObject>) { this.raw = raw; }
              getValues(): Array<Record<string, ESObject>> | undefined {
                const values: Object | undefined = this.raw['values'] as Object | undefined;
                if (values && values instanceof Array) {
                  return values as Array<Record<string, ESObject>>;
                }
                return undefined;
              }
            }
            const exceptionRecordRaw = exceptionCandidateRaw as Record<string, ESObject>;
            const exceptionWrapper = new ExceptionRecordWrapper(exceptionRecordRaw);
            const valuesArr = exceptionWrapper.getValues();
            if (valuesArr && valuesArr.length > 0) {
              hasException = true;
            }
          }
          if (eventIdCandidate && eventIdCandidate.length > 0) {
            if (hasException || levelLower === 'error' || levelLower === 'fatal') {
              try { SentryOhos.registerErrorEventId(eventIdCandidate); } catch (_) {}
            }
          }
          // 注入 tags/contexts
          const tagsObj = (evObj['tags'] as Record<string, ESObject>) || ({} as Record<string, ESObject>);
          tagsObj['replayId'] = rid as ESObject;
          evObj['tags'] = tagsObj as ESObject;
          const ctxObj = (evObj['contexts'] as Record<string, ESObject>) || ({} as Record<string, ESObject>);
          const replayCtx: Record<string, ESObject> = { 'replay_id': rid as ESObject, 'id': rid as ESObject, 'type': 'replay' as ESObject };
          ctxObj['replay'] = replayCtx as ESObject;
          evObj['contexts'] = ctxObj as ESObject;
          const newEvStr = JSON.stringify(evObj);
          const newEvBytes = this.encodeUtf8(newEvStr);
          // 更新 header.length
          hdrObj['length'] = newEvBytes.length as ESObject;
          const newHdrStr = JSON.stringify(hdrObj);
          const newHdrBytes = this.encodeUtf8(newHdrStr);
          // 追加：header\n + payload\n
          parts.push(newHdrBytes); parts.push(new Uint8Array([LF]));
          parts.push(newEvBytes); parts.push(new Uint8Array([LF]));
          // 跳过原始 payload 与原始换行
          pos = payloadEnd;
          if (pos < src.length && src[pos] === LF) pos += 1;
          injected = true;
        } else if (hasLen && payloadEnd <= src.length) {
          // 原样抄写 header + LF + payload + LF (Copy original bytes to avoid re-encoding issues)
          parts.push(src.subarray(hdrStart, hdrEnd)); parts.push(new Uint8Array([LF]));
          parts.push(src.subarray(payloadStart, payloadEnd)); parts.push(new Uint8Array([LF]));
          pos = payloadEnd;
          if (pos < src.length && src[pos] === LF) pos += 1;
        } else {
          // 异常：无法确定长度，直接将剩余全部抄写并退出
          parts.push(src.subarray(hdrStart, hdrEnd)); parts.push(new Uint8Array([LF]));
          parts.push(src.subarray(pos));
          pos = src.length;
          break;
        }
      }
      // 合并输出
      let total = 0; for (let i = 0; i < parts.length; i++) total += parts[i].length;
      const out = new Uint8Array(total); let off = 0;
      for (let i = 0; i < parts.length; i++) { out.set(parts[i], off); off += parts[i].length; }
      try { if (injected) console.info('[replay][envelope] injected rid into event item'); } catch (_) {}
      return out;
    } catch (_) { return src; }
  }

  async captureEnvelopeFromPath(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      const path = call.argument('path') as string | null;
      const containsUnhandled = !!call.argument('containsUnhandled');
      if (!path || path.length === 0) {
        result.error("3", "Envelope path is null or empty", null);
        return;
      }
      try {
        console.log('captureEnvelopeFromPath path=' + path);
        const stat = fs.statSync(path);
        const size = (stat.size as number) || 0;
        if (size <= 0) {
          result.error("3", "Envelope file is empty", null);
          return;
        }
        const file = fs.openSync(path, 0o444);
        const buf = new Uint8Array(size);
        fs.readSync(file.fd, buf);
        fs.closeSync(file);
        try {
          InternalSentrySdk.captureEnvelopeBytes(buf, containsUnhandled);
        } catch (_) {
          result.error("2", "Failed to capture envelope from path", null);
          return;
        }
        result.success("");
      } catch (e) {
        result.error("2", "Failed to read envelope file", null);
      }
    } catch (err) {
      result.error("2", "Failed to capture envelope from path", null);
    }
  }

  loadImageList(call: MethodCall, result: MethodResult): void {
    try {
      const addresses = call.args as Array<string> | null;
      let images: Array<Record<string, Object>> = [];
      try {
        if (addresses && addresses.length > 0) {
          const list: Array<DebugImage> = DebugImagesLoader.loadDebugImagesForAddresses(addresses);
          images = list.map((img: DebugImage): Record<string, Object> => img.toJson());
        } else {
          const list: Array<DebugImage> = DebugImagesLoader.loadDebugImages();
          images = list.map((img: DebugImage): Record<string, Object> => img.toJson());
        }
      } catch (_) {
        images = [] as Array<Record<string, Object>>;
      }
      result.success(images as Object);
    } catch (_) {
      try { result.success([] as Object); } catch (_) {}
    }
  }

  closeNativeSdk(result: MethodResult): void {
    try {
      result.success(true);
    } catch (err) {
      result.success(false);
    }
  }

  fetchNativeAppStart(result: MethodResult): void {
    try {
      // Provide a minimal App Start payload aligned with Android structure
      // Keys required by Dart side: appStartTime (double msSinceEpoch), pluginRegistrationTime (int msSinceEpoch),
      // isColdStart (boolean), nativeSpanTimes (map)
      const nowMs: number = Date.now();
      const pluginMs: number = (this.pluginRegistrationTime ?? nowMs);
      // Assume warm start with small delta before plugin registration
      const appStartMs: number = Math.max(0, pluginMs - 500);
      const payload: Record<string, Object> = {};
      // appStartTime expects a double on Dart side
      payload['appStartTime'] = appStartMs as Object;
      // pluginRegistrationTime expects an int on Dart side; use floor to avoid decimals
      payload['pluginRegistrationTime'] = Math.floor(pluginMs) as Object;
      payload['isColdStart'] = false as Object;
      const nativeSpanTimes: Record<string, Object> = {};
      payload['nativeSpanTimes'] = nativeSpanTimes as Object;
      result.success(payload as Object);
    } catch (_) {
      try { result.success(null); } catch (_) {}
    }
  }

  setContexts(key: string | null, value: ESObject | null, result: MethodResult): void {
    try {
      if (key === null || value === null) {
        result.error(Error_Code, Message, Details);
        return;
      };
      Sentry.setContext(key, value);
      try { result.success(""); } catch (_) {}
    } catch (err) {
      console.error('[SentryFlutterPlugin] setContexts err:',err?.message);
    }
  }

  removeContexts(key: string | null, result: MethodResult): void {
    try {
      if (key === null) {
        result.error(Error_Code, Message, Details);
        return;
      };
      Sentry.removeContext(key);
      try { result.success(""); } catch (_) {}
    } catch (err) {
      console.error('[SentryFlutterPlugin] removeContexts err:',err?.message);
    }
  }

  setUser(user: Map<string, ESObject> | null, result: MethodResult): void {
    try {
      if (user == null) {
        console.error('user is null');
        result.error(Error_Code, Message, Details);
        return;
      };
      const u = new User()
      u.id = user.get('id');
      u.email = user.get('email');
      u.ip_address = user.get('ip_address');
      u.username = user.get('username');
      Sentry.setUser(u);
      try { result.success(""); } catch (_) {}
    } catch (err) {
      console.error('[SentryFlutterPlugin] setUser err:',err?.message);
    }
  }

  addBreadcrumb(breadcrumb: Map<string, ESObject> | null, result: MethodResult): void {
    try {
      if (breadcrumb == null) {
        result.error(Error_Code, Message, Details);
        return;
      }
      const b = new Breadcrumb();
      b.timestamp = breadcrumb.get('timestamp');
      b.message = breadcrumb.get('message');
      b.category = breadcrumb.get('category');
      b.type = breadcrumb.get('type');
      b.data = breadcrumb.get('data');
      b.level = breadcrumb.get('level') as SentryLevel;
      Sentry.addBreadcrumb(b);
      try { result.success(""); } catch (_) {}
    } catch (err) {
      console.error('[SentryFlutterPlugin] addBreadcrumb err:',err?.message)
    }
  }

  clearBreadcrumbs(result: MethodResult): void {
    try {
      Sentry.clearBreadcrumbs();
      try { result.success(""); } catch (_) {}
    } catch (err) {
      console.error('[SentryFlutterPlugin] clearBreadcrumbs err:',err?.message);
    }
  }

  setExtra(key: string | null, value: ESObject | null, result: MethodResult): void {
    try {
      if (key === null || value === null) {
        result.error(Error_Code, Message, Details);
        return;
      };
      Sentry.setExtra(key, value);
      try { result.success(""); } catch (_) {}
    } catch (err) {
      console.error('[SentryFlutterPlugin] setExtra err:',err?.message)
    }
  }

  removeExtra(key: string | null, result: MethodResult): void {
    try {
      if (key === null) {
        result.error(Error_Code, Message, Details);
        return;
      }
      Sentry.removeExtra(key);
      try { result.success(""); } catch (_) {}
    } catch (err) {
      console.error('[SentryFlutterPlugin] removeExtra err:',err?.message)
    }
  }

  setTag(key: string | null, value: ESObject | null, result: MethodResult): void {
    try {
      if (key === null || value === null) {
        result.error(Error_Code, Message, Details);
        return;
      }
      Sentry.setTag(key, value);
      try { result.success(""); } catch (_) {}
    } catch (err) {
      console.error('[SentryFlutterPlugin] setTag err:',err?.message)
    }
  }

  removeTag(key: string | null, result: MethodResult): void {
    try {
      if (key === null) {
        result.error(Error_Code, Message, Details);
        return;
      }
      Sentry.removeTag(key);
      try { result.success(""); } catch (_) {}
    } catch (err) {
      console.error('[SentryFlutterPlugin] removeTag err:',err?.message)
    }
  }

  loadContexts(result: MethodResult): void {
    try {
      // 即时采集并拼装完整 contexts，字段命名对齐 Android
      const hub = Sentry.getHub();
      const options = hub.getOptions();

      const deviceCtx = collectDeviceContext();
      const appCtx = collectAppContext();
      const runtimeCtx = collectRuntimeContext();
      const ltz = getLocaleTimezone();

      const contexts: Record<string, Object> = {};

      // OS
      const osCtx: Record<string, Object> = {};
      osCtx['name'] = 'OpenHarmony' as Object;
      const kernel = getKernelVersion();
      if (kernel !== undefined) osCtx['kernel_version'] = kernel as Object;
      if (typeof (deviceCtx['osVersion']) === 'string') osCtx['version'] = deviceCtx['osVersion'] as Object;
      if (typeof (deviceCtx['build']) === 'string') osCtx['build'] = deviceCtx['build'] as Object;
      const rootedMaybe = detectRooted();
      if (typeof rootedMaybe === 'boolean') osCtx['rooted'] = rootedMaybe as Object;
      contexts['os'] = osCtx as Object;

      // Device（尽可能对齐 Android 字段命名）
      const dev: Record<string, Object> = {};
      if (typeof (deviceCtx['model']) === 'string') dev['model'] = deviceCtx['model'] as Object;
      if (typeof (deviceCtx['model']) === 'string') dev['family'] = deviceCtx['model'] as Object;
      if (typeof (deviceCtx['modelId']) === 'string') dev['model_id'] = deviceCtx['modelId'] as Object;
      if (typeof (deviceCtx['brand']) === 'string') dev['brand'] = deviceCtx['brand'] as Object;
      if (typeof (deviceCtx['manufacturer']) === 'string') dev['manufacturer'] = deviceCtx['manufacturer'] as Object;
      if (typeof (deviceCtx['chipset']) === 'string') dev['chipset'] = deviceCtx['chipset'] as Object;
      if (typeof (deviceCtx['deviceId']) === 'string') dev['id'] = deviceCtx['deviceId'] as Object;
      // 屏幕信息
      if (typeof (deviceCtx['screenWidth']) === 'number') dev['screen_width_pixels'] = deviceCtx['screenWidth'] as Object;
      if (typeof (deviceCtx['screenHeight']) === 'number') dev['screen_height_pixels'] = deviceCtx['screenHeight'] as Object;
      if (typeof (deviceCtx['screenDensity']) === 'number') dev['screen_density'] = deviceCtx['screenDensity'] as Object;
      if (typeof (deviceCtx['screenDpi']) === 'number') dev['screen_dpi'] = deviceCtx['screenDpi'] as Object;
      // 连接/在线
      if (runtimeCtx.networkType !== undefined) {
        dev['connection_type'] = runtimeCtx.networkType as Object;
        dev['online'] = (runtimeCtx.networkType !== 'none') as Object;
      }
      // 电池/充电
      if (typeof runtimeCtx.batteryLevel === 'number') dev['battery_level'] = runtimeCtx.batteryLevel as Object;
      if (typeof runtimeCtx.isCharging === 'boolean') dev['charging'] = runtimeCtx.isCharging as Object;
      // 内存（bytes）
      if (typeof runtimeCtx.memoryTotalMb === 'number') dev['memory_size'] = Math.floor(runtimeCtx.memoryTotalMb * 1024 * 1024) as Object;
      if (typeof runtimeCtx.memoryUsedMb === 'number' && typeof runtimeCtx.memoryTotalMb === 'number') {
        const freeMb = runtimeCtx.memoryTotalMb - runtimeCtx.memoryUsedMb;
        if (freeMb >= 0) dev['free_memory'] = Math.floor(freeMb * 1024 * 1024) as Object;
      }
      // 存储
      if (typeof (deviceCtx['storageSize']) === 'number') dev['storage_size'] = deviceCtx['storageSize'] as Object;
      if (typeof (deviceCtx['freeStorage']) === 'number') dev['free_storage'] = deviceCtx['freeStorage'] as Object;
      // 处理器
      const cpuCount = getProcessorCount();
      if (typeof cpuCount === 'number') dev['processor_count'] = cpuCount as Object;
      if (runtimeCtx.cpuFrequencyMHz !== undefined) dev['processor_frequency'] = runtimeCtx.cpuFrequencyMHz as Object;
      // 体系结构
      if (typeof (deviceCtx['archs']) === 'string') {
        const a = (deviceCtx['archs'] as string).split(',');
        dev['archs'] = a as Object;
      }
      // 语言/时区
      if (ltz.locale) dev['locale'] = ltz.locale as Object;
      if (ltz.timezone) dev['timezone'] = ltz.timezone as Object;
      // 其它
      if (runtimeCtx.bootTime) dev['boot_time'] = runtimeCtx.bootTime as Object;
      contexts['device'] = dev as Object;

      // App
      const appOut: Record<string, Object> = {};
      if (appCtx['appName'] !== undefined) appOut['app_name'] = appCtx['appName'] as Object;
      if (appCtx['packageName'] !== undefined) appOut['app_identifier'] = appCtx['packageName'] as Object;
      if (appCtx['appVersion'] !== undefined) appOut['app_version'] = appCtx['appVersion'] as Object;
      if (appCtx['appBuild'] !== undefined) appOut['app_build'] = appCtx['appBuild'] as Object;
      // 内存（bytes）
      if (typeof runtimeCtx.memoryUsedMb === 'number') appOut['app_memory'] = Math.floor(runtimeCtx.memoryUsedMb * 1024 * 1024) as Object;
      // 前后台/启动时间（尽量提供）
      appOut['in_foreground'] = true as Object;
      if (appCtx['appStartIso'] !== undefined) appOut['app_start_time'] = appCtx['appStartIso'] as Object;
      // 权限
      if (typeof (appCtx['permissionsCsv']) === 'string') {
        const p: Array<string> = (appCtx['permissionsCsv'] as string).split(',');
        appOut['permissions'] = p as Object;
      }
      // 其它
      appOut['text_scale'] = (1.0 as number) as Object;
      const viewNames: Array<string> = ['/'];
      appOut['view_names'] = viewNames as Object;
      appOut['is_split_apks'] = false as Object;
      contexts['app'] = appOut as Object;

      // culture
      const culture: Record<string, Object> = {};
      culture['locale'] = (ltz.locale || 'en-US') as Object;
      culture['timezone'] = (ltz.timezone || 'CST') as Object;
      culture['is_24_hour_format'] = true as Object;
      contexts['culture'] = culture as Object;

      // accessibility（OHOS 暂无直接 API，提供默认值）
      const acc: Record<string, Object> = {};
      acc['accessible_navigation'] = false as Object;
      acc['bold_text'] = false as Object;
      acc['disable_animations'] = false as Object;
      acc['high_contrast'] = false as Object;
      acc['invert_colors'] = false as Object;
      acc['reduce_motion'] = false as Object;
      contexts['accessibility'] = acc as Object;

      // 组装输出
      const out: Record<string, Object> = {};
      out['contexts'] = contexts as Object;

      // 保留 scope 中的 tags/extra/user/fingerprint/level（若存在）
      const scope = InternalSentrySdk.getCurrentScope();
      const s = InternalSentrySdk.serializeScope(scope) as Record<string, Object>;
      const tags: Record<string, Object> = (s['tags'] as Record<string, Object>) ?? ({} as Record<string, Object>);
      const extras: Record<string, Object> = (s['extras'] as Record<string, Object>) ?? ({} as Record<string, Object>);
      const user: Record<string, Object> = (s['user'] as Record<string, Object>) ?? ({} as Record<string, Object>);
      const fingerprint: Array<Object> = (s['fingerprint'] as Array<Object>) ?? ([] as Array<Object>);
      out['tags'] = tags as Object;
      out['extra'] = extras as Object;
      out['user'] = user as Object;
      out['fingerprint'] = fingerprint as Object;
      out['level'] = ((s['level'] as Object) || '') as Object;

      if (typeof options.dist === 'string' && options.dist.length > 0) out['dist'] = options.dist as Object;
      if (typeof options.environment === 'string' && options.environment.length > 0) out['environment'] = options.environment as Object;
      const integrations: Array<string> = [];
      out['integrations'] = integrations as Object;

      result.success(out as Object);
    } catch (err) {
      console.error('[SentryFlutterPlugin] loadContexts err:', err?.message);
      // 即便异常也返回空，避免阻塞
      result.success({});
    }
  }

  displayRefreshRate(result: MethodResult): void {
    try {
      // 尝试从系统显示服务获取刷新率（与安卓逻辑等价：优先真实值，失败时回退默认值）
      const def = display.getDefaultDisplaySync();
      if (def) {
        interface DisplayWithRefresh { refreshRate?: number; vsyncRate?: number; fps?: number }
        const d = def as DisplayWithRefresh;
        const r1 = typeof d.refreshRate === 'number' ? d.refreshRate : undefined;
        const r2 = typeof d.vsyncRate === 'number' ? d.vsyncRate : undefined;
        const r3 = typeof d.fps === 'number' ? d.fps : undefined;
        const rate = r1 ?? r2 ?? r3;
        if (typeof rate === 'number' && rate > 0 && isFinite(rate)) {
          result.success(Math.floor(rate));
          return;
        }
      }
      // 回退：常见设备为 60Hz
      result.success(60);
    } catch (_) {
      try { result.success(null); } catch (_) {}
    }
  }

  nativeCrash(): void {
    try {
      // 触发原生层崩溃（等价 Android MainActivity.crash → native-sample）
      NdkSample.crash();
    } catch (_) {
      // 若原生库不可用，退化为异步未处理异常，至少可被 installGlobalErrorHandler 捕获
      // 注意：此退化不会杀进程，仅用于验证未处理异常链路
      setTimeout(() => { throw new Error('ArkTS fatal crash (fallback)'); }, 0);
    }
  }

  setReplayConfig(call: MethodCall, result: MethodResult): void {
    try {
      const windowWidth = call.argument('windowWidth') as number | null;
      const windowHeight = call.argument('windowHeight') as number | null;
      const width = call.argument('width') as number | null;
      const height = call.argument('height') as number | null;
      const frameRate = call.argument('frameRate') as number | null;
      // OHOS 端未使用bitRate视频编码，忽略

      // 仅在启用了 Replay 时应用配置
      if (this.replayEnabled) {
        // 以 frameRate 为主，将其转换为帧间隔；未提供则保持默认
        if (typeof frameRate === 'number' && frameRate > 0) {
          const frameIntervalMs = Math.max(1, Math.floor(1000 / frameRate));
          try { configureReplaySampling({ frameIntervalMs: frameIntervalMs }); } catch (_) {}
        }
        // 保留同名配置对象，便于未来切换为系统录屏（AVScreenCaptureRecorder）策略
        try {
          if (typeof width === 'number' && typeof height === 'number' && typeof windowWidth === 'number' && typeof windowHeight === 'number') {
            const cfg = new ScreenshotRecorderConfig(
              width,
              height,
              width / Math.max(1, windowWidth),
              height / Math.max(1, windowHeight),
              (typeof frameRate === 'number' && frameRate > 0) ? frameRate : 2,
              0
            );
            // 当前 OHOS 采用定时截图，不需要显式传递 cfg，但保留创建以对齐 Android API
          }
        } catch (_) {}
        // 通过桥接类通知 Dart 端更新采集配置（对齐 Android）
        try {
          if (this.replayEnabled && this.replayRecorder) {
            this.replayRecorder.onConfigurationChanged(width ?? 0, height ?? 0, (typeof frameRate === 'number' && frameRate > 0) ? frameRate : 2);
          }
        } catch (_) {}
      }
      try { result.success(""); } catch (_) {}
    } catch (_) {
      try { result.success(""); } catch (_) {}
    }
  }

  private setLastErrorEventId(call: MethodCall, result: MethodResult): void {
    try {
      const eventId = call.argument('eventId') as string | null;
      if (eventId && eventId.length > 0) {
        this.pendingReplayErrorEventId = eventId;
        try { SentryOhos.registerErrorEventId(eventId); } catch (_) {}
      }
      try { result.success(""); } catch (_) {}
    } catch (_) {
      try { result.success(""); } catch (_) {}
    }
  }

  async captureReplay(result: MethodResult): Promise<void> {
    try {
      if (!this.replayEnabled) {
        try { result.success(""); } catch (_) {}
        return;
      }
      const ctx: common.BaseContext | null = this.applicationContext
        ? (this.applicationContext as common.BaseContext)
        : (this.binding ? (this.binding.getApplicationContext() as common.BaseContext) : null);
      if (ctx) {
        try { updateReplayContext(ctx); } catch (_) {}
        const errorEventId = this.pendingReplayErrorEventId;
        try { await captureReplayOnError(ctx, errorEventId); } catch (_) {}
        this.pendingReplayErrorEventId = undefined;
      }
      // 返回当前 replay_id（若存在），与 Android 行为对齐
      let rid: string = "";
      try { const id = getReplayId(); rid = typeof id === 'string' ? id : ""; } catch (_) { rid = ""; }
      try { result.success(rid); } catch (_) {}
    } catch (e) {
      try { result.success(""); } catch (_) {}
    }
  }
}
