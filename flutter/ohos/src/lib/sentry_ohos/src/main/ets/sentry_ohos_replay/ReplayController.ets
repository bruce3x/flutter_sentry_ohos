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

import { ReplayEvent } from './ReplayEvent';
import { UIComponent, TextInputComponent } from './Component';
import { GestureCapture } from './GestureCapture';
import { InputCapture } from './InputCapture';
import { ViewSnapshot } from './ViewSnapshot';
// 屏幕帧方案已移除：仅使用组件快照与交互事件组合回放
import { SessionManager } from './SessionManager';
import { ReplayTransport } from './ReplayTransport';
import { PrivacyConfig } from './PrivacyConfig';
import { SamplingConfig } from './SamplingConfig';
import { ReplayCache } from './ReplayCache';
import { ReplayPayload, ReplayPayloadEvent, ShapeFramePayload } from './types';
import { ShapeFrameBuilder, ComponentLayoutInfo } from './ShapeFrameBuilder';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import media from '@ohos.multimedia.media';
import fileio from '@ohos.fileio';
import window from '@ohos.window';
import { ShapeFrameRenderer } from './ShapeFrameRenderer';
import { ArkTsVideoEncoder } from './ArkTsVideoEncoder';
import { ShapeVideoEncoder } from './ShapeVideoEncoder';
import { SentryOhos } from '../core/SentryOhos';
import image from '@ohos.multimedia.image';
import { Sentry } from '../sentry/Sentry';
import { BreadcrumbStore, Breadcrumb } from '../sentry/Breadcrumb';
import { DefaultReplayBreadcrumbConverter } from './DefaultReplayBreadcrumbConverter';
import type { RRWebBreadcrumbEvent } from './rrweb/RRWebBreadcrumbEvent';
import type { RRWebSpanEvent } from './rrweb/RRWebSpanEvent';
import { DefaultReplaySpanConverter } from './DefaultReplaySpanConverter';
import { TraceManager } from '../core/TraceManager';
import { SurfaceTextureRegistryEntry } from '@ohos/flutter_ohos';
import { replayInfo, replayWarn, replayDebug } from './ReplayLogger';

interface AppStorageCompat {
  get?: (key: string) => Object | undefined;
  setOrCreate?: (key: string, value: Object) => void;
}

interface GlobalWithAppStorageCompat {
  AppStorage?: AppStorageCompat;
  __sentryReplayUiContext?: Object;
}

interface VideoReadinessResult {
  path?: string;
  size?: number;
}

interface Mp4MetricsDiagnostic {
  foundMvhd?: boolean;
  timescale?: number;
  duration?: number;
  durationMs?: number;
  version?: number;
}

interface VideoPathCandidate {
  label: string;
  path?: string;
  size?: number;
}

interface PixelMapBufferReader {
  readPixelsToBuffer?: (buffer: ArrayBuffer) => Promise<void>;
}

interface PixelMapLegacyReader {
  readPixelsToBuffer: (buffer: ArrayBuffer, callback: PixelMapReadCallback) => void;
}

class PixelMapReadError {
  public message: string;
  constructor(message: string) {
    this.message = message;
  }
}

type PixelMapReadCallback = (err?: PixelMapReadError) => void;

class PixelBufferSelectionImpl {
  public buffer: ArrayBuffer;
  public stride: number;

  constructor(buffer: ArrayBuffer, stride: number) {
    this.buffer = buffer;
    this.stride = stride;
  }
}

interface SamplePoint {
  x: number;
  y: number;
}

interface AbilityInfoCompat {
  type?: string | number;
}

interface AbilityInfoProviderCompat {
  abilityInfo?: AbilityInfoCompat;
}

interface WindowStageHolderCompat {
  windowStage?: Object;
}

class ReplayUiContextWrapper {
  private readonly host: common.BaseContext;

  constructor(ctx: common.BaseContext) {
    this.host = ctx;
  }

  public getHostContext(): common.BaseContext {
    return this.host;
  }
}

const REPLAY_UI_CONTEXT_KEY: string = 'SentryReplayUiContext';
const MIN_VIDEO_SIZE_BYTES: number = 40 * 1024; // 40KB
const MIN_VIDEO_DURATION_MS: number = 1500; // 1.5s

// 整合手势、输入、屏幕、快照、上传
export interface ReplayControllerOptions {
  uiComponents: UIComponent[];
  textInputs: TextInputComponent[];
  autoStart?: boolean;
  bufferMode?: boolean; // 缓冲模式（错误触发发送）
  serverUrl?: string;
  sessionSampleRate?: number;
  onErrorSampleRate?: number;
  enableScreenFrames?: boolean; // 默认关闭像素级屏幕帧，避免敏感信息泄露
}

export class ReplayController {
  private gestureCapture: GestureCapture;
  private inputCapture: InputCapture;
  private viewSnapshot: ViewSnapshot;
  private sessionManager: SessionManager;
  private eventTransport: ReplayTransport;
  private privacy: PrivacyConfig;
  private sampling: SamplingConfig;
  private cache: ReplayCache;
  private enableScreenFrames: boolean;
  private shapeBuilder: ShapeFrameBuilder;
  private latestLayouts: ComponentLayoutInfo[] = [];
  private recordingOutputPath?: string; // 形状视频输出（目录或MP4）
  private recordingOutputSize?: number;
  private renderer: ShapeFrameRenderer;
  private encoder?: ArkTsVideoEncoder;
  private flutterEncoderInitialized: boolean = false;
  private flutterFrameWidth: number = 0;
  private flutterFrameHeight: number = 0;

  private autoStart: boolean;
  private bufferMode: boolean;
  private serverUrl?: string;

  private frameTimer?: number;
  private segmentStartMs: number = 0;
  private recordingStartMs: number = 0;
  private context?: common.BaseContext;
  private isPaused: boolean = false;
  private isConnected: boolean = true;
  private isRateLimited: boolean = false;
  private isScrolling: boolean = false; // 滑动状态标志
  private scrollingSuppressedUntil: number = 0;
  private readonly scrollingCooldownMs: number = 800; // 滑动期间跳过截图，避免主线程阻塞
  private readonly scrollingResumeDelayMs: number = 450; // 滑动结束后延迟恢复，等待物理惯性结束
  private firstFrameDelayMs: number = 500; // 第一帧延迟时间，减少到500ms以尽快开始捕获
  private firstFrameCaptured: boolean = false; // 是否已捕获第一帧
  private captureWarmupMs: number = 1000; // 启动后前1秒使用降频策略
  private warmupCaptureIntervalMs: number = 200; // 暖机期间的最小截图间隔，调整为200ms（5FPS）
  private lastWarmupCaptureTs: number = 0;
  private heavyCaptureThresholdMs: number = 120; // 超过该耗时判定为重载
  private heavyCaptureCooldownMs: number = 4000; // 重载后暂停截图的时间
  private adaptiveCaptureResumeTs: number = 0;
  private lastAdaptiveLogTs: number = 0;
  private previousReplayFinalized: boolean = false; // 防止finalizePreviousReplay重复调用

  constructor(options: ReplayControllerOptions) {
    // 初始化捕获器
    this.gestureCapture = new GestureCapture(options.uiComponents);
    this.privacy = new PrivacyConfig();
    this.inputCapture = new InputCapture(options.textInputs, this.privacy);
    this.viewSnapshot = new ViewSnapshot(this.privacy);
    this.sessionManager = new SessionManager();
    this.eventTransport = new ReplayTransport();
    this.sampling = new SamplingConfig();
    if (typeof options.sessionSampleRate === 'number') {
      this.sampling.sessionSampleRate = Math.max(0, Math.min(options.sessionSampleRate, 1));
    }
    if (typeof options.onErrorSampleRate === 'number') {
      this.sampling.onErrorSampleRate = Math.max(0, Math.min(options.onErrorSampleRate, 1));
    }
    this.cache = new ReplayCache();
    this.shapeBuilder = new ShapeFrameBuilder();
    this.renderer = new ShapeFrameRenderer();

    // 默认不上传像素帧：对齐 Sentry Android 的“形状回放”隐私策略
    this.enableScreenFrames = options.enableScreenFrames === true ? true : false;
    // 默认开启全局图片遮罩：组件快照与屏幕帧都不包含实际像素
    try { this.privacy.setMaskAllImages(true); } catch (_) {}

    this.autoStart = options.autoStart ?? false;
    this.bufferMode = options.bufferMode ?? false;
    this.serverUrl = options.serverUrl;
    SurfaceTextureRegistryEntry

    if (this.autoStart) {
      this.start();
    }

    // 注意：不在此处调用finalizePreviousReplay，因为此时ReplayCache的cacheFile还未设置
    // finalizePreviousReplay会在updateContext中调用，届时cache已有正确的文件路径
  }

  /** 开始捕获 */
  public start(): void {
    if (!this.segmentStartMs) {
      this.segmentStartMs = Date.now();
      this.recordingStartMs = this.segmentStartMs;
    }
    this.isPaused = false;
    this.firstFrameCaptured = false; // 重置第一帧标志
    this.gestureCapture.startCapture();
    this.inputCapture.startCapture();
    this.sessionManager.startSession();
    replayInfo('ReplayController', '已开始捕获用户操作');
    this.lastWarmupCaptureTs = 0;
    this.adaptiveCaptureResumeTs = 0;
    // 将当前 replay_id 写入全局 tag，便于官方 SDK 上报的错误自动携带并在 Web 侧关联
    try {
      const s = this.sessionManager.getSession();
      if (s && s.id) { Sentry.setTag('replayId', s.id); }
    } catch (_) {}

    // 启动原生截图编码（新方案：使用 componentSnapshot 组件截图 API，避免 window.snapshot() 阻塞）
    // 参考：https://zhuanlan.zhihu.com/p/25261681579
    // componentSnapshot 比 window.snapshot() 更高效，且不会阻塞主线程
    if (this.enableScreenFrames && this.context) {
      if (!this.encoder) {
        this.encoder = new ArkTsVideoEncoder();
        this.encoder.setBufferConfig(this.bufferMode, this.sampling.errorReplayDurationMs || 30000);
        this.encoder.setStartTime(this.recordingStartMs);
        this.flutterEncoderInitialized = false;
        this.flutterFrameWidth = 0;
        this.flutterFrameHeight = 0;
      }
      // 注意：不在这里初始化编码器，而是在第一次捕获到帧时，使用实际帧的分辨率初始化
      // 这样可以避免分辨率不匹配导致的重新初始化问题
      const fps = this.sampling.frameRate;
      const interval = Math.max(1, Math.floor(1000 / fps));
      type IntervalFn = () => Promise<void>;
      const tick: IntervalFn = async () => {
        if (this.isPaused) {
          // 如果暂停，跳过截图
          return;
        }
        if (!this.encoder) {
          return;
        }
        // 第一帧延迟，确保界面已完全渲染
        // 但允许尝试截图，只有在成功捕获后才设置标志
        if (!this.firstFrameCaptured) {
          const elapsed = Date.now() - this.recordingStartMs;
          if (elapsed < this.firstFrameDelayMs) {
            // 延迟期间不进行像素抓取，避免主线程卡顿，也避免录到白屏
            replayDebug('ReplayController', 'waiting for firstFrameDelay (elapsed=' + String(elapsed) + 'ms / ' + String(this.firstFrameDelayMs) + 'ms)');
            return;
          }
        }
        // 使用 setTimeout 将截图操作延迟到下一个事件循环，避免阻塞当前 tick
        setTimeout(async () => {
          if (this.isPaused || !this.encoder || !this.context) {
            return;
          }
          const nowTs = Date.now();
          /*
          if (this.isScrolling) {
            if (nowTs - this.lastAdaptiveLogTs > 1000) {
              this.lastAdaptiveLogTs = nowTs;
              replayDebug('ReplayController', 'scroll skip: gesture in progress, suppressing capture');
            }
            this.scrollingSuppressedUntil = nowTs + this.scrollingCooldownMs;
            return;
          }
          */
          if (this.scrollingSuppressedUntil > nowTs) {
            if (nowTs - this.lastAdaptiveLogTs > 1000) {
              this.lastAdaptiveLogTs = nowTs;
              replayDebug('ReplayController', 'scroll skip: cooldown=' + String(this.scrollingSuppressedUntil - nowTs) + 'ms');
            }
            return;
          }
          const elapsedSinceStart = nowTs - this.recordingStartMs;
          if (this.adaptiveCaptureResumeTs > nowTs) {
            if (nowTs - this.lastAdaptiveLogTs > 1000) {
              this.lastAdaptiveLogTs = nowTs;
              replayDebug('ReplayController', 'adaptive throttle skip frame (cooldown=' + String(this.adaptiveCaptureResumeTs - nowTs) + 'ms)');
            }
            return;
          }
          if (elapsedSinceStart < this.captureWarmupMs) {
            if (this.lastWarmupCaptureTs > 0 &&
              (nowTs - this.lastWarmupCaptureTs) < this.warmupCaptureIntervalMs) {
              replayDebug('ReplayController', 'warmup throttle skip frame (elapsed=' + String(elapsedSinceStart) + 'ms)');
              return;
            }
          } else if (this.lastWarmupCaptureTs !== 0) {
            this.lastWarmupCaptureTs = 0;
          }
          // 滑动时不跳过截图，但可以降低帧率（通过间隔控制）
          // 这样滑动过程也能被记录
          try {
            const captureStart = Date.now();
            // 如果编码器尚未初始化，先使用默认分辨率初始化（后续会根据实际帧分辨率调整）
            // 这样可以确保 captureSnapshot() 时编码器已经有上下文（baseContext 和 ctx）
            // 虽然会导致编码器被初始化两次（720x1280 → 实际分辨率），但可以确保 captureSnapshot() 正常工作
            if (!this.encoder.isInitialized()) {
              replayDebug('ReplayController', 'encoder not initialized, initializing with default resolution 720x1280 for captureSnapshot');
              this.encoder.init(this.context, 720, 1280, this.sampling.frameRate);
            }

            // 使用组件级截图优先（componentSnapshot），失败时才回退到 window.snapshot()
            // 这样可以优先在更小的像素区域完成采集，减少 UI 线程负担
            const pm = await this.encoder.captureSnapshot();
            if (elapsedSinceStart < this.captureWarmupMs) {
              this.lastWarmupCaptureTs = nowTs;
            }
            const snapshotDuration = Date.now() - captureStart;
            if (snapshotDuration > this.heavyCaptureThresholdMs) {
              this.adaptiveCaptureResumeTs = Date.now() + this.heavyCaptureCooldownMs;
              this.lastAdaptiveLogTs = Date.now();
              replayWarn('ReplayController', 'snapshot heavy load detected, duration=' + String(snapshotDuration) + 'ms, cooldown=' + String(this.heavyCaptureCooldownMs) + 'ms');
            }
            if (pm) {
              const timestamp = Date.now();
              // 使用 appendFrame 直接传递 PixelMap，避免在 ArkTS 层进行 readPixelsToBuffer (同步/阻塞)
              // 让 encoder 内部决定最佳处理方式 (Native Surface / EncodePixelMap / Fallback)
              try {
                await this.encoder.appendFrame(pm, timestamp);
                
                if (!this.firstFrameCaptured) {
                  this.firstFrameCaptured = true;
                  const elapsed = Date.now() - this.recordingStartMs;
                  replayDebug('ReplayController', 'first frame captured after ' + String(elapsed) + 'ms');
                }
              } catch (e) {
                replayWarn('ReplayController', 'appendFrame error: ' + String(e));
              } finally {
                // 释放 PixelMap
                try {
                  interface PixelMapReleasable { release?: () => void }
                  const pmm: PixelMapReleasable = (pm as PixelMapReleasable);
                  if (typeof pmm.release === 'function') pmm.release();
                } catch (_) {}
              }
            } else {
              replayWarn('ReplayController', 'captureSnapshot failed: pm is undefined');
            }
          } catch (e) {
            replayWarn('ReplayController', 'captureAndEncodeNativeScreenshot error: ' + String(e));
          }
        }, 0);
      };
      // ArkTS 中 setInterval 返回 number，这里显式转换
      const timerId: number = Number(setInterval(tick, interval));
      this.frameTimer = timerId;
      replayDebug('ReplayController', '[PERF] started component snapshot capture with interval ' + String(interval) + 'ms');
    }
  }

  /** 停止捕获（终止会话） */
  public async stop(): Promise<void> {
    this.gestureCapture.stopCapture();
    this.inputCapture.stopCapture();
    this.sessionManager.endSession();
    replayInfo('ReplayController', '已停止捕获用户操作');
    if (this.frameTimer !== undefined) {
      clearInterval(this.frameTimer);
      this.frameTimer = undefined;
    }
    this.isPaused = true;
    // 结束视频编码，等待 finalize 完成后再上传（确保文件已落盘）
    try {
      if (this.encoder && this.context && this.enableScreenFrames) {
        const out = await this.encoder.finalize(this.context);
        this.recordingOutputPath = out;
        this.recordingOutputSize = this.safeStatSize(out);
        this.flutterEncoderInitialized = false;
        this.flutterFrameWidth = 0;
        this.flutterFrameHeight = 0;
        if (this.recordingOutputPath && this.serverUrl) {
          SentryOhos.sendAttachment(this.recordingOutputPath, 'replay_recording.mp4', 'video/mp4');
        }
      }
    } catch (_) {}
  }

  /** 暂停（进入后台或离线/限流） */
  public pause(): void {
    if (this.isPaused) return;
    this.isPaused = true;
    this.gestureCapture.stopCapture();
    this.inputCapture.stopCapture();
    if (this.frameTimer !== undefined) {
      clearInterval(this.frameTimer);
      this.frameTimer = undefined;
    }
  }

  /** 恢复（回到前台，且联网且未限流） */
  public resume(): void {
    if (!this.isPaused) return;
    if (!this.isConnected || this.isRateLimited) {
      return;
    }
    this.isPaused = false;
    this.gestureCapture.startCapture();
    this.inputCapture.startCapture();
    // 恢复形状帧编码
    if (this.enableScreenFrames && this.context) {
      if (!this.encoder) {
        this.encoder = new ArkTsVideoEncoder();
        this.encoder.setBufferConfig(this.bufferMode, this.sampling.errorReplayDurationMs || 30000);
        this.flutterEncoderInitialized = false;
        this.flutterFrameWidth = 0;
        this.flutterFrameHeight = 0;
      }
      const w = 720, h = 1280, fps = this.sampling.frameRate;
      this.encoder.init(this.context, w, h, fps);
      const interval = Math.max(1, Math.floor(1000 / this.sampling.frameRate));
      type IntervalFn2 = () => Promise<void>;
      const tick2: IntervalFn2 = async () => {
        try {
          const frame = this.shapeBuilder.buildFrame(this.latestLayouts, Date.now());
          const pm = await this.renderer.renderToPixelMap(frame, { width: w, height: h });
          await this.encoder?.appendFrame(pm, frame.timestamp);
      try {
        interface PixelMapReleasable { release?: () => void }
        const pmm: PixelMapReleasable = (pm as PixelMapReleasable);
        if (typeof pmm.release === 'function') pmm.release();
      } catch (e) {
        // ignore release errors
      }
    } catch (e) {
      // ignore tick errors
    }
      };
      const timerId2: number = Number(setInterval(tick2, interval));
      this.frameTimer = timerId2;
    }
    // 恢复后重置当前分段起点，避免跨后台造成超长段
    this.segmentStartMs = Date.now();
  }

  /** App 前台 */
  public onAppForeground(): void {
    this.resume();
  }

  /** App 后台：会话模式可尝试刷新一段 */
  public async onAppBackground(): Promise<void> {
    this.pause();
    if (!this.bufferMode && this.serverUrl && this.context) {
      try {
        await this.uploadReplay(this.serverUrl, this.context);
      } catch (_) {}
    }
  }

  /** 配置采样参数（帧率/分段时长等） */
  public configureSampling(frameRate?: number, sessionSegmentDurationMs?: number): void {
    if (typeof frameRate === 'number' && frameRate > 0) {
      this.sampling.frameRate = Math.max(1, Math.floor(frameRate));
    }
    if (typeof sessionSegmentDurationMs === 'number' && sessionSegmentDurationMs > 0) {
      this.sampling.sessionSegmentDurationMs = sessionSegmentDurationMs;
    }
  }

  // 简化的视频编码原型：以形状帧渲染为位图并写入 MP4（占位，留待后续完善编码器参数）
  private async renderShapeFrameToMp4(frame: ShapeFramePayload): Promise<void> {
    try {
      // 伪代码：此处仅占位，实际应使用 AVScreenCaptureRecorder 或 VideoEncoder 管线
      // 我们采用缓存帧图 -> 合成短视频的策略；当前先落空，待编码链路补齐
      if (!this.recordingOutputPath && this.context) {
        interface FileDirProvider { filesDir?: string; cacheDir?: string }
        const p = this.context as FileDirProvider;
        const baseDir: string | undefined = (typeof p.filesDir === 'string')
          ? (p.filesDir as string)
          : (typeof p.cacheDir === 'string' ? (p.cacheDir as string) : undefined);
        if (baseDir !== undefined) {
          this.recordingOutputPath = `${baseDir}/replay_${Date.now()}.mp4`;
        }
      }
    } catch (_) {}
  }

  /** 当前回放会话 ID（replay_id） */
  public getCurrentSessionId(): string | undefined {
    const s = this.sessionManager.getSession();
    return s ? s.id : undefined;
  }

  /** 连接状态（离线时暂停，仅会话模式有效） */
  public setConnectionStatus(connected: boolean): void {
    this.isConnected = connected;
    if (!this.bufferMode) {
      if (!connected) {
        this.pause();
      } else {
        this.resume();
      }
    }
  }

  /** 速率限制状态（限流时暂停，仅会话模式有效） */
  public setRateLimited(rateLimited: boolean): void {
    this.isRateLimited = rateLimited;
    if (!this.bufferMode) {
      if (rateLimited) {
        this.pause();
      } else {
        this.resume();
      }
    }
  }

  /** 获取所有捕获事件（手势 + 输入） */
  public getCapturedEvents(): ReplayEvent[] {
    const gestureEvents = this.gestureCapture.getCapturedEvents();
    const inputEvents = this.inputCapture.getCapturedEvents();
    return [...gestureEvents, ...inputEvents].sort((a, b) => a.timestamp - b.timestamp);
  }

  /** 清空所有捕获事件 */
  public clear(): void {
    this.gestureCapture.clearEvents();
    this.inputCapture.clearCapturedEvents();
    // 无屏幕帧：无需清理
  }

  /** 动态绑定/解绑 UI 组件用于手势与快照 */
  public registerUIComponentForReplay(ui: UIComponent, arkComponent: ESObject): void {
    this.gestureCapture.addComponent(ui);
    this.viewSnapshot.registerComponent(ui, arkComponent);
  }

  public unregisterUIComponentForReplay(ui: UIComponent): void {
    this.gestureCapture.removeComponent(ui.id);
    this.viewSnapshot.unregisterComponent(ui);
  }

  /** 上传 Replay 到服务端 */
  public async uploadReplay(serverUrl: string, context: common.BaseContext): Promise<boolean> {
    replayInfo('ReplayController', 'uploadReplay called');
    this.serverUrl = serverUrl || this.serverUrl;
    this.context = context || this.context;
    const session = this.sessionManager.getSession();
    if (!session) return false;
    if (!this.sampling.shouldSampleSession()) return false;

    const gestureEvents: ReplayPayloadEvent = {
      type: "gesture",
      data: this.gestureCapture.getCapturedEvents()
    };

    const inputEvents: ReplayPayloadEvent = {
      type: "input",
      data: this.inputCapture.getCapturedEvents()
    };

    // 使用矢量形状帧替代像素快照：由 UI 侧注入最新布局 latestLayouts
    const shapeFrames: ShapeFramePayload = { timestamp: Date.now(), shapes: [] };
    try {
      const frame = this.shapeBuilder.buildFrame(this.latestLayouts, Date.now());
      shapeFrames.timestamp = frame.timestamp;
      shapeFrames.shapes = frame.shapes;
    } catch (_) {}
    const snapshotEvents: ReplayPayloadEvent = { type: "snapshot", data: [shapeFrames] as Array<ShapeFramePayload> };

    // 仅上传组件快照与手势/输入

    // 转换 Breadcrumb 为 RRWeb 事件（可选）
    let rrwebBreadcrumbs: Array<RRWebBreadcrumbEvent> = [];
    try {
      // 使用公开 getter，避免索引式访问
      const store = SentryOhos.getBreadcrumbStore();
      const crumbsCore = store ? store.snapshot() : [];
      const converted: Array<RRWebBreadcrumbEvent> = [];
      for (let i = 0; i < crumbsCore.length; i++) {
        const bc = crumbsCore[i] as Breadcrumb;
        const ev = DefaultReplayBreadcrumbConverter.convert(bc);
        if (ev) converted.push(ev);
      }
      rrwebBreadcrumbs = converted;
    } catch (_) {}

    const breadcrumbEvents: ReplayPayloadEvent = { type: 'breadcrumb', data: rrwebBreadcrumbs as Array<Object> } as ReplayPayloadEvent;

    // 转换 Span 为 RRWeb 事件（可选，取当前活跃 Transaction 的 spans）
    let rrwebSpans: Array<RRWebSpanEvent> = [];
    try {
      const tm = TraceManager.get();
      const spans = tm.getActiveSpans();
      if (spans) {
        const converted: Array<RRWebSpanEvent> = [];
        for (let i = 0; i < spans.length; i++) {
          const ev = DefaultReplaySpanConverter.convert(spans[i]);
          if (ev) converted.push(ev);
        }
        rrwebSpans = converted;
      }
    } catch (_) {}

    const spanEvents: ReplayPayloadEvent = { type: 'span', data: rrwebSpans as Array<Object> } as ReplayPayloadEvent;

    const effectiveContext = this.context ?? context;
    let preparedVideo: VideoReadinessResult = {};
    if (this.enableScreenFrames && this.encoder && effectiveContext) {
      try {
        preparedVideo = await this.ensureVideoReady(effectiveContext);
      } catch (err) {
        // ignore video preparation errors
      }
    }

    const nowSec = Math.floor(Date.now() / 1000);
    const payload: ReplayPayload = {
      sessionId: session.id,
      events: [gestureEvents, inputEvents, snapshotEvents, breadcrumbEvents, spanEvents],
      replay_id: session.id,
      segment_id: 0,
      started_at: new Date(this.recordingStartMs).toISOString(),
      finished_at: new Date().toISOString(),
      replay_start_timestamp: Math.floor(this.recordingStartMs / 1000),
      timestamp: nowSec,
      urls: ['/'],
      replay_type: 'session',
      platform: 'android'
    };
    // 注入 trace_ids（若有活跃事务）
    try {
      const snap = TraceManager.get().getActiveTraceSnapshot();
      if (snap && typeof snap.trace_id === 'string' && snap.trace_id.length > 0) {
        (payload as ReplayPayload).trace_ids = [snap.trace_id];
      }
    } catch (_) {}

    // 若已记录视频，注入路径和大小（用于调试日志与服务端校验）
    // 优先级：preparedVideo（最新finalize的） > recordingOutputPath（已保存的） > encoder（正在录制的）
    // 确保选择最新且完整的视频文件
    const videoPathCandidates: Array<VideoPathCandidate> = [];
    if (preparedVideo.path) {
      const preparedCandidate: VideoPathCandidate = { label: 'prepared', path: preparedVideo.path, size: preparedVideo.size };
      videoPathCandidates.push(preparedCandidate);
    }
    if (this.recordingOutputPath) {
      const recordingCandidate: VideoPathCandidate = { label: 'recordingOutput', path: this.recordingOutputPath, size: this.recordingOutputSize };
      videoPathCandidates.push(recordingCandidate);
    }
    if (this.encoder) {
      try {
        const encoderCandidate: VideoPathCandidate = {
          label: 'encoder',
          path: this.encoder.getOutputPath(),
          size: this.encoder.getOutputSize()
        };
        videoPathCandidates.push(encoderCandidate);
      } catch (_) {}
    }
    let selectedPath: string | undefined;
    let selectedSize: number | undefined;
    let selectedCandidate: VideoPathCandidate | undefined;
    // 遍历所有候选文件，选择最大且有效的文件（通常是最新且完整的）
    for (let i = 0; i < videoPathCandidates.length; i++) {
      const candidate = videoPathCandidates[i];
      if (!candidate.path) {
        continue;
      }
      const statSize = this.safeStatSize(candidate.path);
      const resolvedSize = typeof statSize === 'number' ? statSize : (typeof candidate.size === 'number' ? candidate.size : undefined);
      // 只考虑有效的文件（大小>0）
      if (resolvedSize && typeof resolvedSize === 'number' && resolvedSize > 0) {
        // 如果还没有选择文件，或者当前文件更大（通常意味着更完整），则选择它
        if (!selectedCandidate || (selectedSize && resolvedSize > selectedSize)) {
          selectedPath = candidate.path;
          selectedSize = resolvedSize;
          selectedCandidate = candidate;
        }
      }
    }
    if (selectedPath) {
      const metrics = this.computeMp4Metrics(selectedPath);
      const skipVideo = this.shouldSkipVideo(selectedSize, metrics.durationMs);
      if (!skipVideo) {
        (payload as ReplayPayload).videoPath = selectedPath;
        if (typeof selectedSize === 'number') {
          (payload as ReplayPayload).videoSizeBytes = selectedSize;
          this.recordingOutputSize = selectedSize;
        } else {
          const fallbackSize = this.safeStatSize(selectedPath);
          if (typeof fallbackSize === 'number') {
            (payload as ReplayPayload).videoSizeBytes = fallbackSize;
            this.recordingOutputSize = fallbackSize;
          }
        }
        this.recordingOutputPath = selectedPath;
      }
    }
    this.cache.save(payload);
    const success = await this.eventTransport.sendReplay(serverUrl, payload);
    if (success) { this.cache.clear(); }
    // Session 模式：基于切片时长滚动
    if (!this.bufferMode) {
      const now = Date.now();
      if (now - this.segmentStartMs >= this.sampling.sessionSegmentDurationMs) {
        this.segmentStartMs = now;
        this.clear();
        try { if (typeof payload.segment_id === 'number') { payload.segment_id = (payload.segment_id as number) + 1; } } catch (_) {}
      }
      if (now - this.recordingStartMs >= this.sampling.sessionDurationMs) {
        this.stop();
      }
    }
    return success;
  }

  /** 在错误事件发生时触发捕获（缓冲模式用） */
  public async captureReplayOnError(context: common.BaseContext, errorEventId?: string): Promise<boolean> {
    // 显式触发的 onError 捕获：即使非 bufferMode 或采样率为 0 也强制发送 rrweb（像素帧可能已禁用）
    const session = this.sessionManager.getSession();
    if (!session) return false;

    // 仅取最近 errorReplayDurationMs 内的事件
    const cutoff = Date.now() - this.sampling.errorReplayDurationMs;
    const gestures = this.gestureCapture.getCapturedEvents().filter(e => e.timestamp >= cutoff);
    const inputs = this.inputCapture.getCapturedEvents().filter(e => e.timestamp >= cutoff);
    const snapshotEvents: ReplayPayloadEvent = { type: 'snapshot', data: [] as Array<ShapeFramePayload> };
    // 补充 breadcrumb/span，确保 rrweb 存在可渲染事件
    let rrwebBreadcrumbs: Array<RRWebBreadcrumbEvent> = [];
    try {
      const store = SentryOhos.getBreadcrumbStore();
      const crumbsCore = store ? store.snapshot() : [];
      const converted: Array<RRWebBreadcrumbEvent> = [];
      for (let i = 0; i < crumbsCore.length; i++) {
        const bc = crumbsCore[i] as Breadcrumb;
        const ev = DefaultReplayBreadcrumbConverter.convert(bc);
        if (ev) converted.push(ev);
      }
      rrwebBreadcrumbs = converted;
    } catch (_) {}
    const breadcrumbEvents: ReplayPayloadEvent = { type: 'breadcrumb', data: rrwebBreadcrumbs as Array<Object> } as ReplayPayloadEvent;

    let rrwebSpans: Array<RRWebSpanEvent> = [];
    try {
      const tm = TraceManager.get();
      const spans = tm.getActiveSpans();
      if (spans) {
        const converted: Array<RRWebSpanEvent> = [];
        for (let i = 0; i < spans.length; i++) {
          const ev = DefaultReplaySpanConverter.convert(spans[i]);
          if (ev) converted.push(ev);
        }
        rrwebSpans = converted;
      }
    } catch (_) {}
    const spanEvents: ReplayPayloadEvent = { type: 'span', data: rrwebSpans as Array<Object> } as ReplayPayloadEvent;
    const nowSec = Math.floor(Date.now() / 1000);
    const videoWidthHint: number | undefined = this.flutterFrameWidth > 0 ? this.flutterFrameWidth : undefined;
    const videoHeightHint: number | undefined = this.flutterFrameHeight > 0 ? this.flutterFrameHeight : undefined;
    const frameRateHint: number | undefined = this.sampling.frameRate > 0 ? this.sampling.frameRate : undefined;

    // 如果启用了视频（像素帧），payload.started_at 必须与视频文件的实际开始时间（recordingStartMs）一致
    // 否则 Sentry Web 端会将视频的 0:00 对齐到 started_at，导致时间轴错位（例如 42s 的视频被当作 10s 播放，或错误点偏移）
    // events 数组仍然可以被截断（cutoff），Sentry 支持这种情况
    const hasVideo = (this.encoder || this.recordingOutputPath) !== undefined;
    const effectiveStartMs = hasVideo ? this.recordingStartMs : Math.max(this.segmentStartMs, cutoff);

    const payload: ReplayPayload = {
      sessionId: session.id,
      events: [ { type: 'gesture', data: gestures }, { type: 'input', data: inputs }, snapshotEvents, breadcrumbEvents, spanEvents ],
      replay_id: session.id,
      segment_id: 0,
      started_at: new Date(effectiveStartMs).toISOString(),
      finished_at: new Date().toISOString(),
      replay_start_timestamp: Math.floor(effectiveStartMs / 1000),
      timestamp: nowSec,
      urls: ['/'],
      replay_type: 'error',
      platform: 'android',
      videoWidth: videoWidthHint,
      videoHeight: videoHeightHint,
      videoFrameRate: frameRateHint
    };
    // 注入 trace_ids / error_ids（最佳努力）
    try {
      const snap = TraceManager.get().getActiveTraceSnapshot();
      if (snap && typeof snap.trace_id === 'string' && snap.trace_id.length > 0) {
        (payload as ReplayPayload).trace_ids = [snap.trace_id];
      }
    } catch (_) {}
    try {
      const errorIds: Array<string> = [];
      if (errorEventId && errorEventId.length > 0) {
        errorIds.push(errorEventId);
      }
      const fallbackEid = session.id + '-' + String(nowSec);
      if (errorIds.indexOf(fallbackEid) === -1) {
        errorIds.push(fallbackEid);
      }
      (payload as ReplayPayload).error_ids = errorIds;
    } catch (_) {}

    // 强制捕获最后一帧，确保视频包含错误发生时的那一刻（避免因定时器间隔导致的末尾缺失）
    if (this.enableScreenFrames && this.encoder && context) {
      try {
        const finalPm = await this.encoder.captureSnapshot();
        if (finalPm) {
          await this.encoder.appendFrame(finalPm, Date.now());
          try {
            interface PixelMapReleasable { release?: () => void }
            const pmm: PixelMapReleasable = (finalPm as PixelMapReleasable);
            if (typeof pmm.release === 'function') pmm.release();
          } catch (_) {}
          replayDebug('ReplayController', 'captureReplayOnError: forced final frame capture success');
        }
      } catch (err) {
        replayWarn('ReplayController', 'captureReplayOnError: failed to capture final frame: ' + String(err));
      }
    }

    // 使用与 uploadReplay 相同的视频文件选择逻辑，确保选择最新且完整的视频文件
    const preparedVideo = await this.ensureVideoReady(context);
    const videoPathCandidates: Array<VideoPathCandidate> = [];
    if (preparedVideo.path) {
      const preparedCandidate: VideoPathCandidate = { label: 'prepared', path: preparedVideo.path, size: preparedVideo.size };
      videoPathCandidates.push(preparedCandidate);
    }
    if (this.recordingOutputPath) {
      const recordingCandidate: VideoPathCandidate = { label: 'recordingOutput', path: this.recordingOutputPath, size: this.recordingOutputSize };
      videoPathCandidates.push(recordingCandidate);
    }
    if (this.encoder) {
      try {
        const encoderCandidate: VideoPathCandidate = {
          label: 'encoder',
          path: this.encoder.getOutputPath(),
          size: this.encoder.getOutputSize()
        };
        videoPathCandidates.push(encoderCandidate);
      } catch (_) {}
    }
    let selectedPath: string | undefined;
    let selectedSize: number | undefined;
    let selectedCandidate: VideoPathCandidate | undefined;
    // 遍历所有候选文件，选择最大且有效的文件（通常是最新且完整的）
    for (let i = 0; i < videoPathCandidates.length; i++) {
      const candidate = videoPathCandidates[i];
      if (!candidate.path) {
        continue;
      }
      const statSize = this.safeStatSize(candidate.path);
      const resolvedSize = typeof statSize === 'number' ? statSize : (typeof candidate.size === 'number' ? candidate.size : undefined);
      // 只考虑有效的文件（大小>0）
      if (resolvedSize && typeof resolvedSize === 'number' && resolvedSize > 0) {
        // 如果还没有选择文件，或者当前文件更大（通常意味着更完整），则选择它
        if (!selectedCandidate || (selectedSize && resolvedSize > selectedSize)) {
          selectedPath = candidate.path;
          selectedSize = resolvedSize;
          selectedCandidate = candidate;
        }
      }
    }
    if (selectedPath && typeof selectedSize === 'number' && selectedSize > 0) {
      const metrics = this.computeMp4Metrics(selectedPath);
      (payload as ReplayPayload).videoPath = selectedPath;
      (payload as ReplayPayload).videoSizeBytes = selectedSize;
      if (videoWidthHint && videoWidthHint > 0) {
        (payload as ReplayPayload).videoWidth = videoWidthHint;
      }
      if (videoHeightHint && videoHeightHint > 0) {
        (payload as ReplayPayload).videoHeight = videoHeightHint;
      }
      if (frameRateHint && frameRateHint > 0) {
        (payload as ReplayPayload).videoFrameRate = frameRateHint;
      }
    } else {
      // 若像素帧被禁用或无可用视频，制造一个最小的占位 mp4 附件（对齐 Android 命名）
      try {
        const fake = this.createFakeMp4IfNeeded(context);
        if (fake && this.serverUrl) {
          try { SentryOhos.sendAttachment(fake, 'replay_recording.mp4', 'video/mp4'); } catch (_) {}
        }
      } catch (_) {}
    }
    this.cache.save(payload);
    if (!this.serverUrl) { return false; }
    const ok = await this.eventTransport.sendReplay(this.serverUrl, payload);
    if (ok) {
      // 发送成功后清理老数据
      this.gestureCapture.rotate(cutoff);
      this.inputCapture.clearCapturedEvents();
      // 无屏幕帧：无需清理
    }
    return ok;
  }

  public async enqueueFlutterFrame(buffer: ArrayBuffer, width: number, height: number, stride: number, timestamp: number): Promise<void> {
    if (!(buffer instanceof ArrayBuffer)) {
      return;
    }
    if (!this.context) {
      return;
    }
    if (!this.enableScreenFrames) {
      this.enableScreenFrames = true;
    }
    if (!this.encoder) {
      this.encoder = new ArkTsVideoEncoder();
      this.flutterEncoderInitialized = false;
      this.flutterFrameWidth = 0;
      this.flutterFrameHeight = 0;
    }
    const fps = this.sampling.frameRate > 0 ? this.sampling.frameRate : 2;
    const originalWidth = width > 0 ? Math.floor(width) : (this.flutterFrameWidth > 0 ? this.flutterFrameWidth : 720);
    const originalHeight = height > 0 ? Math.floor(height) : (this.flutterFrameHeight > 0 ? this.flutterFrameHeight : 1280);

    // HarmonyOS 视频编码器要求分辨率必须是16的倍数，且最小为256x256
    // 提高最小分辨率以避免编码器配置失败（错误码3：invalid argument）
    // 对齐分辨率时保持原始宽高比，避免图像变形
    const ALIGNMENT = 16;
    const MIN_SIZE = 256; // 最小尺寸（宽度或高度中的较大值）

    // 计算原始宽高比
    const aspectRatio = originalWidth > 0 && originalHeight > 0 ? originalWidth / originalHeight : 1.0;

    // 确定目标尺寸：保持宽高比，确保较大的边至少为 MIN_SIZE
    let targetWidth = originalWidth;
    let targetHeight = originalHeight;

    if (targetWidth < MIN_SIZE && targetHeight < MIN_SIZE) {
      // 如果两个尺寸都小于最小值，按比例放大，使较大的边达到最小值
      if (targetWidth >= targetHeight) {
        targetWidth = MIN_SIZE;
        targetHeight = Math.ceil(MIN_SIZE / aspectRatio);
      } else {
        targetHeight = MIN_SIZE;
        targetWidth = Math.ceil(MIN_SIZE * aspectRatio);
      }
    } else if (targetWidth < MIN_SIZE) {
      // 如果宽度小于最小值，按比例放大
      targetWidth = MIN_SIZE;
      targetHeight = Math.ceil(MIN_SIZE / aspectRatio);
    } else if (targetHeight < MIN_SIZE) {
      // 如果高度小于最小值，按比例放大
      targetHeight = MIN_SIZE;
      targetWidth = Math.ceil(MIN_SIZE * aspectRatio);
    }

    // 对齐到16的倍数（用于编码器初始化）
    let encoderWidth = Math.ceil(targetWidth / ALIGNMENT) * ALIGNMENT;
    let encoderHeight = Math.ceil(targetHeight / ALIGNMENT) * ALIGNMENT;

    const tsMs = timestamp > 0 ? Math.floor(timestamp) : Date.now();
    if (!this.flutterEncoderInitialized || encoderWidth !== this.flutterFrameWidth || encoderHeight !== this.flutterFrameHeight) {
      this.encoder.init(this.context, encoderWidth, encoderHeight, fps);
      this.flutterEncoderInitialized = true;
      this.flutterFrameWidth = encoderWidth;
      this.flutterFrameHeight = encoderHeight;
    }
    try {
      // 传递原始分辨率 + 对齐分辨率，appendRawFrame 内部负责 padding 并保持编码器维度一致
      await this.encoder.appendRawFrame(
        buffer,
        originalWidth,
        originalHeight,
        stride,
        tsMs,
        encoderWidth,
        encoderHeight,
      );
      replayDebug('ReplayController', 'enqueueFlutterFrame: original=' + String(originalWidth) + 'x' + String(originalHeight)
        + ', encoder=' + String(encoderWidth) + 'x' + String(encoderHeight)
        + ', stride=' + String(stride) + ', bufferBytes=' + String(buffer.byteLength));
    } catch (err) {
      replayWarn('ReplayController', 'enqueueFlutterFrame: appendRawFrame error: ' + String(err));
      // ignore append errors
    }
  }

  // 创建一个最小占位 MP4，非严格标准，仅用于测试上传路径
  private createFakeMp4IfNeeded(ctx: common.BaseContext): string | undefined {
    try {
      interface FileDirProvider { filesDir?: string; cacheDir?: string }
      const p = ctx as FileDirProvider;
      const base: string | undefined = p.filesDir ?? p.cacheDir;
      if (!base) return undefined;
      const path = `${base}/replay_recording.mp4`;
      // 若已存在且非空，复用
      try { const st = fs.statSync(path); if ((st?.size as number) > 0) return path; } catch (_) {}
      const O_CREAT = 0o100; const O_RDWR = 0o2;
      const fd = fileio.openSync(path, O_CREAT | O_RDWR, 0o666);
      // 写入简单占位数据
      // 简单 UTF-8 编码替代，避免依赖 TextEncoder
      const txt = 'FAKE_MP4';
      const headerArr: number[] = [];
      for (let i = 0; i < txt.length; i++) { headerArr.push(txt.charCodeAt(i) & 0xFF); }
      const header = new Uint8Array(headerArr);
      const padding = new Uint8Array(1024);
      fileio.writeSync(fd, header);
      fileio.writeSync(fd, padding);
      fileio.closeSync(fd);
      return path;
    } catch (_) { return undefined; }
  }

  /** 更新上下文以启用定时屏幕采集 */
  public updateContext(ctx: common.BaseContext): void {
    this.context = ctx;
    this.cache.setContext(ctx);
    this.persistUiContext(ctx);
    // 检测是否为 UIAbility 上下文：若无法取得窗口，不应立即禁用像素帧（可能因生命周期过早），交由 Encoder 延迟重试
    if (this.enableScreenFrames) {
      (async () => {
        try {
          await window.getLastWindow(ctx);
        } catch (e) {
          replayWarn('ReplayController', 'updateContext: getLastWindow failed (transient?), keeping screen frames enabled. err=' + String(e));
        }
      })();
    }
  }

  private persistUiContext(ctx: common.BaseContext): void {
    try {
      const globalCandidate = globalThis as GlobalWithAppStorageCompat;
      const storage = globalCandidate.AppStorage;
      const incomingIsUi = this.isUiAbilityContext(ctx);
      const existingWrapper = this.readStoredUiContext(storage, globalCandidate);
      if (!incomingIsUi && existingWrapper) {
        const existingHost = existingWrapper.getHostContext();
        if (existingHost && this.isUiAbilityContext(existingHost)) {
          return;
        }
      }
      const wrapper = new ReplayUiContextWrapper(ctx);
      if (storage && typeof storage.setOrCreate === 'function') {
        storage.setOrCreate(REPLAY_UI_CONTEXT_KEY, wrapper as Object);
      }
        globalCandidate.__sentryReplayUiContext = wrapper as Object;
    } catch (_) {}
  }

  private readStoredUiContext(storage: AppStorageCompat | undefined, globalCandidate: GlobalWithAppStorageCompat): ReplayUiContextWrapper | undefined {
    let stored: Object | undefined;
    if (storage && typeof storage.get === 'function') {
      stored = storage.get(REPLAY_UI_CONTEXT_KEY);
    } else {
      stored = globalCandidate.__sentryReplayUiContext;
    }
    if (stored && (stored as ReplayUiContextWrapper).getHostContext) {
      return stored as ReplayUiContextWrapper;
    }
    return undefined;
  }

  private isUiAbilityContext(ctx: common.BaseContext | undefined): boolean {
    if (!ctx) {
      return false;
    }
    const provider = ctx as AbilityInfoProviderCompat;
    const abilityInfo = provider && provider.abilityInfo;
    const typeValue = abilityInfo ? abilityInfo.type : undefined;
    let result = false;
    if (typeof typeValue === 'number') {
      result = typeValue === 1;
    } else if (typeof typeValue === 'string') {
      const normalized = typeValue.trim().toLowerCase();
      result = normalized === 'uiability' || normalized === 'ui' || normalized === '1';
    }
    const ctorName = this.getContextConstructorName(ctx);
    if (!result && (ctorName === 'UIAbilityContext' || ctorName === 'AbilityContext')) {
      result = true;
    }
    if (!result) {
      try {
        const stageHolder = ctx as WindowStageHolderCompat;
        if (stageHolder && stageHolder.windowStage) {
          result = true;
      }
    } catch (_) {}
    }
    return result;
  }

  private getContextConstructorName(target: Object | undefined): string {
    if (!target) {
      return '';
    }
    try {
      const ctor = (target as Object).constructor as Function | undefined;
      if (ctor && typeof ctor.name === 'string') {
        return ctor.name;
      }
    } catch (_) {}
    return '';
  }

  // 供 API 更新布局信息
  public __setLayouts(layouts: ComponentLayoutInfo[]): void {
    this.latestLayouts = layouts || [];
  }

  /** 遮罩/解遮罩指定组件的快照 */
  public maskComponent(componentId: string): void {
    this.privacy.maskComponent(componentId);
  }

  public unmaskComponent(componentId: string): void {
    this.privacy.unmaskComponent(componentId);
  }

  /** 全局：是否遮罩所有文本输入 */
  public setMaskAllText(enabled: boolean): void {
    if (enabled) {
      this.privacy.enableMasking();
    } else {
      this.privacy.disableMasking();
    }
  }

  /** 全局：是否遮罩所有图像（快照/屏幕） */
  public setMaskAllImages(enabled: boolean): void {
    this.privacy.setMaskAllImages(enabled);
  }

  public setScrollingState(isScrolling: boolean): void {
    this.isScrolling = isScrolling;
    const now = Date.now();
    if (isScrolling) {
      this.scrollingSuppressedUntil = now + this.scrollingCooldownMs;
      this.adaptiveCaptureResumeTs = Math.max(this.adaptiveCaptureResumeTs, this.scrollingSuppressedUntil);
    } else {
      this.scrollingSuppressedUntil = now + this.scrollingResumeDelayMs;
    }
  }

  /** 应用启动后补发上次缓存并清理 */
  private async finalizePreviousReplay(): Promise<void> {
    try {
      const previous = this.cache.load();
      if (!previous || !this.serverUrl) {
        return;
      }
      const ok = await this.eventTransport.sendReplay(this.serverUrl, previous);
      if (ok) {
        this.cache.clear();
      }
    } catch (_) {
      // ignore
    }
  }

  // 屏幕帧上传已废除

  private async ensureVideoReady(context: common.BaseContext, timeoutMs: number = 3000): Promise<VideoReadinessResult> {
    // 保存编码器引用，避免在检查过程中被设置为 undefined
    const encoderRef = this.encoder;
    if (!encoderRef) {
      return {};
    }
    // 如果 enableScreenFrames 为 false，但编码器存在，仍然尝试 finalize（可能是在 captureReplayOnError 中调用）
    if (!this.enableScreenFrames) {
    }
    if (!(this.context ?? context)) {
      replayDebug('ReplayController', 'ensureVideoReady: context not available');
      return {};
    }
    const effectiveContext = this.context ?? context;
    const start = Date.now();
    const checkInterval = 150; // Check every 150ms


    // First, wait for any pending frames to be processed (with timeout)
    const frameProcessingTimeout = Math.min(timeoutMs, 2000); // Max 2s for frame processing
    let frameProcessingStart = Date.now();
    let hasOutput = false;
    while (Date.now() - frameProcessingStart < frameProcessingTimeout) {
      // Check if encoder has any pending work
      try {
        const sizeProbe = encoderRef.getOutputSize();
        const pathProbe = encoderRef.getOutputPath();
        // If encoder has output, it means some frames have been processed
        if (pathProbe && typeof sizeProbe === 'number' && sizeProbe > 0) {
          hasOutput = true;
          break; // Some frames processed, proceed to finalize
        }
      } catch (err) {
        replayDebug('ReplayController', 'ensureVideoReady: probe error: ' + String(err));
      }
      await this.delay(checkInterval);
    }

    if (!hasOutput) {
    }

    // Wait a bit more to ensure all queued frames are processed
    await this.delay(500); // Increased from 300ms to 500ms to give more time for frame processing

    // Now finalize the encoder
    let finalizedPath: string | undefined;
    let finalizedSize: number | undefined;
    try {
      finalizedPath = await encoderRef.finalize(effectiveContext);
      if (finalizedPath) {
        finalizedSize = encoderRef.getOutputSize();
        // 如果 getOutputSize() 返回 undefined，尝试直接从文件系统获取
        if (typeof finalizedSize !== 'number' || finalizedSize <= 0) {
          finalizedSize = this.safeStatSize(finalizedPath);
        }
      } else {
      }
    } catch (err) {
      replayWarn('ReplayController', 'ensureVideoReady: finalize error: ' + String(err));
    }
    // 只有在 finalize 成功后才清理编码器引用
    if (finalizedPath && typeof finalizedSize === 'number' && finalizedSize > 0) {
    this.encoder = undefined;
    this.flutterEncoderInitialized = false;
    this.flutterFrameWidth = 0;
    this.flutterFrameHeight = 0;
      this.recordingOutputPath = finalizedPath;
      this.recordingOutputSize = finalizedSize;
      return { path: finalizedPath, size: finalizedSize };
    }
    // 如果 finalize 失败，保留编码器引用，以便后续重试
    return {};
  }

  private async delay(ms: number): Promise<void> {
    await new Promise<void>((resolve) => setTimeout(resolve, ms));
  }

  private safeStatSize(path?: string): number | undefined {
    try {
      if (!path || path.length === 0) {
        return undefined;
      }
      const st = fileio.statSync(path);
      const sizeRaw = st && typeof st.size === 'number' ? (st.size as number) : undefined;
      return typeof sizeRaw === 'number' ? sizeRaw : undefined;
    } catch (_) {
      return undefined;
    }
  }

  private computeMp4Metrics(path: string): Mp4MetricsDiagnostic {
    const result: Mp4MetricsDiagnostic = {};
    let fd: number | undefined;
    try {
      const st = fileio.statSync(path);
      const totalSize = st && typeof st.size === 'number' ? (st.size as number) : 0;
      if (!totalSize || totalSize <= 0) {
        return result;
      }
      const readLen = Math.min(totalSize, 1024 * 1024);
      const buffer = new ArrayBuffer(readLen);
      const O_RDONLY = 0o0;
      fd = fileio.openSync(path, O_RDONLY);
      const bytesRead = fileio.readSync(fd, buffer);
      const len = (typeof bytesRead === 'number' && bytesRead > 0) ? Math.min(bytesRead, readLen) : 0;
      if (len <= 0) {
        return result;
      }
      const bytes = new Uint8Array(buffer, 0, len);
      const idx = this.findFourcc(bytes, 'mvhd');
      result.foundMvhd = idx >= 0;
      if (idx >= 0 && idx + 24 <= bytes.length) {
        const version = bytes[idx + 4];
        result.version = version;
        if (version === 0 && idx + 24 <= bytes.length) {
          const timescale = this.readUint32BE(bytes, idx + 16);
          const duration = this.readUint32BE(bytes, idx + 20);
          result.timescale = timescale;
          result.duration = duration;
          if (timescale > 0) {
            result.durationMs = Math.floor((duration * 1000) / timescale);
          }
        } else if (version === 1 && idx + 32 <= bytes.length) {
          const timescale = this.readUint32BE(bytes, idx + 20);
          const duration64 = this.readUint64BE(bytes, idx + 24);
          result.timescale = timescale;
          result.duration = duration64;
          if (timescale > 0) {
            result.durationMs = Math.floor((duration64 * 1000) / timescale);
          }
        }
      }
    } catch (err) {
      // ignore metrics computation errors
    } finally {
      if (typeof fd === 'number') {
        try { fileio.closeSync(fd); } catch (_) {}
      }
    }
    return result;
  }

  private async obtainPixelBuffer(pm: image.PixelMap, expectedRowBytes: number, targetHeight: number): Promise<PixelBufferSelectionImpl | undefined> {
    // 优先使用 getPixelBytesNumber + 同步 readPixelsToBuffer（参考 ViewSnapshot.ets 的实现）
    // 注意：readPixelsToBuffer 是同步操作，对于大尺寸截图会阻塞主线程
    // 因此使用 Promise 包装，让调用者可以异步等待

    // 首先获取实际图像尺寸，供所有路径使用
    let actualWidth = 0;
    let actualHeight = 0;
    try {
      const info = await pm.getImageInfo();
      actualWidth = info.size ? (info.size.width as number) : 0;
      actualHeight = info.size ? (info.size.height as number) : 0;
    } catch (_) {
      replayWarn('ReplayController', 'obtainPixelBuffer: failed to get image info');
    }

    const targetWidth = expectedRowBytes / 4; // RGBA: 4 bytes per pixel

    // 使用实际图像高度计算 stride，而不是目标高度
    // 因为 buffer 包含的是实际分辨率的像素数据
    const rows = Math.max(1, actualHeight);

    // 优先尝试异步 readPixelsToBuffer（HarmonyOS NEXT 提供），避免主线程阻塞
    const bufferReader = pm as PixelMapBufferReader;
    if (bufferReader && typeof bufferReader.readPixelsToBuffer === 'function') {
      const actualRowBytes = Math.max(1, actualWidth) * 4;
      const buffer = new ArrayBuffer(actualRowBytes * Math.max(1, actualHeight));
      try {
        const maybePromise = bufferReader.readPixelsToBuffer(buffer);
        if (maybePromise && typeof (maybePromise as Promise<void>).then === 'function') {
          await (maybePromise as Promise<void>);
        }
        if (buffer && buffer.byteLength > 0) {
          const stride = this.resolveStrideFromTotal(buffer.byteLength, actualRowBytes, actualHeight);
          replayDebug('ReplayController', 'obtainPixelBuffer: async API success, bufferSize=' + String(buffer.byteLength) + ', stride=' + String(stride));
          return new PixelBufferSelectionImpl(buffer, stride);
        } else {
          replayWarn('ReplayController', 'obtainPixelBuffer: async API returned empty buffer, will fallback to sync path');
        }
      } catch (asyncErr) {
        replayWarn('ReplayController', 'readPixels(async) failed: ' + String(asyncErr) + ', falling back to sync path');
      }
    }

    try {

      // 如果实际尺寸与目标尺寸不匹配，需要缩放
      // 但为了性能，我们直接读取原始 buffer，然后在 appendRawFrame 中处理缩放
      // 这里只读取原始 buffer
      const pixelBytes = pm.getPixelBytesNumber();
      if (typeof pixelBytes === 'number' && pixelBytes > 0) {
        replayDebug('ReplayController', 'obtainPixelBuffer: using getPixelBytesNumber method, pixelBytes=' + String(pixelBytes) + ', actualSize=' + String(actualWidth) + 'x' + String(actualHeight) + ', targetSize=' + String(targetWidth) + 'x' + String(targetHeight));
        const arr = new Uint8Array(pixelBytes);
        const buffer: ArrayBuffer = arr.buffer as ArrayBuffer;

        // 注意：readPixelsToBuffer 是同步操作，会阻塞主线程
        // 即使使用 setTimeout 延迟，它仍然会在主线程上执行
        // 通过降低分辨率（从 1260x2720 到 720x1280），数据量从 13MB 减少到约 3.5MB
        // 这可以显著减少阻塞时间，但无法完全避免阻塞
        // 如果仍然卡顿，建议进一步降低分辨率或增加截图间隔
        try {
          // 同步调用 readPixelsToBuffer（参考 ViewSnapshot.ets 的实现）
          // 这是无法避免的阻塞操作，只能通过降低分辨率来减少影响
          pm.readPixelsToBuffer(buffer);
          if (buffer && buffer.byteLength > 0) {
            // 使用实际图像高度计算 stride
            const stride = this.resolveStrideFromTotal(buffer.byteLength, actualWidth * 4, rows);
            replayDebug('ReplayController', 'obtainPixelBuffer: getPixelBytesNumber success, bufferSize=' + String(buffer.byteLength) + ', stride=' + String(stride));
            return new PixelBufferSelectionImpl(buffer, stride);
          } else {
            replayWarn('ReplayController', 'obtainPixelBuffer: getPixelBytesNumber returned empty buffer');
          }
        } catch (err) {
          replayWarn('ReplayController', 'obtainPixelBuffer: readPixelsToBuffer failed: ' + String(err));
        }
      } else {
        replayWarn('ReplayController', 'obtainPixelBuffer: getPixelBytesNumber returned invalid value: ' + String(pixelBytes));
      }
    } catch (fallbackErr) {
      replayWarn('ReplayController', 'obtainPixelBuffer: getPixelBytesNumber method failed: ' + String(fallbackErr));
    }

    // 最后尝试回调式 API
    const legacyReader = pm as PixelMapLegacyReader;
    if (legacyReader && typeof legacyReader.readPixelsToBuffer === 'function' && legacyReader.readPixelsToBuffer.length >= 2) {
      // 使用实际图像尺寸分配 buffer
      const actualRowBytes = actualWidth * 4; // RGBA: 4 bytes per pixel
      const buffer = new ArrayBuffer(Math.max(1, actualRowBytes) * actualHeight);
      try {
        await new Promise<void>((resolve, reject) => {
          try {
            legacyReader.readPixelsToBuffer(buffer, (err?: PixelMapReadError) => {
              if (err && err.message) {
                reject(new PixelMapReadError(err.message));
              } else if (err) {
                reject(err);
              } else {
                resolve();
              }
            });
          } catch (legacyErr) {
            reject(new PixelMapReadError(String(legacyErr)));
          }
        });
        if (buffer && buffer.byteLength > 0) {
          const stride = this.resolveStrideFromTotal(buffer.byteLength, actualRowBytes, actualHeight);
          replayDebug('ReplayController', 'obtainPixelBuffer: callback API success, bufferSize=' + String(buffer.byteLength) + ', stride=' + String(stride));
          return new PixelBufferSelectionImpl(buffer, stride);
        }
      } catch (err) {
        replayWarn('ReplayController', 'readPixels(callback) failed: ' + String(err));
      }
    }

    replayWarn('ReplayController', 'obtainPixelBuffer: all methods failed, returning undefined');
    return undefined;
  }

  private resolveStrideFromTotal(totalBytes: number, expectedRowBytes: number, rows: number): number {
    if (rows <= 0 || expectedRowBytes <= 0) {
      return expectedRowBytes;
    }
    const actualStride = Math.floor(totalBytes / rows);
    return actualStride >= expectedRowBytes ? actualStride : expectedRowBytes;
  }

  private shouldSkipVideo(size?: number, durationMs?: number): boolean {
    if (typeof size === 'number' && size > 0 && size < MIN_VIDEO_SIZE_BYTES) {
      return true;
    }
    if (typeof durationMs === 'number' && durationMs > 0 && durationMs < MIN_VIDEO_DURATION_MS) {
      return true;
    }
    return false;
  }


  private findFourcc(buf: Uint8Array, fourcc: string): number {
    if (!buf || buf.length === 0 || !fourcc || fourcc.length !== 4) {
      return -1;
    }
    const target0 = fourcc.charCodeAt(0) & 0xFF;
    const target1 = fourcc.charCodeAt(1) & 0xFF;
    const target2 = fourcc.charCodeAt(2) & 0xFF;
    const target3 = fourcc.charCodeAt(3) & 0xFF;
    for (let i = 0; i <= buf.length - 4; i++) {
      if (buf[i] !== target0) continue;
      if (buf[i + 1] !== target1) continue;
      if (buf[i + 2] !== target2) continue;
      if (buf[i + 3] !== target3) continue;
      return i;
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

  private uint8ArrayToBase64(bytes: Uint8Array): string {
    let binary = '';
    const chunkSize = 0x8000; // 32KB
    for (let i = 0; i < bytes.length; i += chunkSize) {
      const sub = bytes.subarray(i, Math.min(i + chunkSize, bytes.length));
      let chunk = '';
      for (let j = 0; j < sub.length; j++) {
        chunk += String.fromCharCode(sub[j]);
      }
      binary += chunk;
    }
    return globalThis.btoa(binary);
  }
}


