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

import image from '@ohos.multimedia.image';
import fs from '@ohos.file.fs';
import fileio from '@ohos.fileio';
import common from '@ohos.app.ability.common';
import { FfmpegVideoEncoder } from './FfmpegVideoEncoder';
import window from '@ohos.window';
import { replayInfo, replayWarn, replayDebug } from './ReplayLogger';

import * as ReplayEncoderNativeStatic from 'libreplay_encoder.so';


interface ReplayEncoderNative {
  init(fd: number, width: number, height: number, fps: number, mime: string): boolean;
  encode(rgba: ArrayBuffer, timestampMs: number): boolean;
  encodePixelMap?: (pixelMap: image.PixelMap, timestampMs: number) => boolean;
  getInputWindow?: () => bigint | undefined;
  finalize(): void;
}

// 根据 NapiTest 示例，oh-package.json5 中的依赖名应该带 .so 后缀
// 但 C++ 中注册的模块名是 replay_encoder（不带 .so 后缀）
// HarmonyOS NAPI 加载器会自动添加 lib 前缀和 .z.so 后缀
const REPLAY_ENCODER_PRIMARY: string = 'replay_encoder'; // C++ 中注册的模块名
const REPLAY_ENCODER_ALT: string = 'libreplay_encoder'; // lib 前缀
const REPLAY_ENCODER_FALLBACK: string = 'libreplay_encoder.so'; // 带后缀
const UI_CONTEXT_STORAGE_KEY: string = 'SentryReplayUiContext';
const SNAPSHOT_MAX_WIDTH: number = 720;
const SNAPSHOT_MAX_HEIGHT: number = 1280;
const SNAPSHOT_MIN_WIDTH: number = 256;
const SNAPSHOT_MIN_HEIGHT: number = 256;
const ROOT_COMPONENT_STRING_ID: string = '-1';
const ROOT_COMPONENT_NUMERIC_ID: number = -1;

type RequireLoader = (module: string) => ReplayEncoderNative | undefined;

interface SystemLoader {
  loadModule?: (moduleName: string, isAsync?: boolean) => void;
}

interface GlobalLoaderProvider {
  requireNapi?: RequireLoader;
  requireNativeModule?: RequireLoader;
}

interface GlobalWithSystem extends GlobalLoaderProvider {
  system?: SystemLoader;
}

function isReplayEncoderNative(target: Object | undefined): boolean {
  if (!target) {
    return false;
  }
  // Check if it matches the interface
  const candidate = target as ReplayEncoderNative;
  return typeof candidate.init === 'function'
    && typeof candidate.encode === 'function'
    && typeof candidate.finalize === 'function';
}

function getSystemLoader(globalObj: GlobalWithSystem): SystemLoader | undefined {
  const loader = globalObj.system;
  if (loader && typeof loader.loadModule === 'function') {
    return loader;
  }
  return undefined;
}

interface NativeModuleExports {
  default?: NativeModuleExports;
  init?: Function;
  encode?: Function;
  finalize?: Function;
}

function acquireReplayEncoder(): ReplayEncoderNative | undefined {
  // Try static import first
  try {
    if (isReplayEncoderNative(ReplayEncoderNativeStatic)) {
        return ReplayEncoderNativeStatic as ReplayEncoderNative;
    }
  } catch (e) {
  }
  
  // 使用动态加载方式（requireNapi）

  try {
    const globalLoaderProvider: GlobalWithSystem = globalThis as GlobalWithSystem;
    const systemLoader: SystemLoader | undefined = getSystemLoader(globalLoaderProvider);
    const loader: RequireLoader | undefined = globalLoaderProvider.requireNapi ?? globalLoaderProvider.requireNativeModule;
    if (typeof loader === 'function') {
      const moduleNames: string[] = [REPLAY_ENCODER_PRIMARY, REPLAY_ENCODER_ALT, REPLAY_ENCODER_FALLBACK];
      for (let i = 0; i < moduleNames.length; i++) {
        const name = moduleNames[i];
        replayDebug('ShapeVideoEncoder', `Attempting to load module: ${name}`);
        const encoder: ReplayEncoderNative | undefined = loader(name);
        if (isReplayEncoderNative(encoder)) {
          replayInfo('ShapeVideoEncoder', `Successfully loaded module: ${name}`);
          return encoder;
        } else {
        }
        try {
          systemLoader?.loadModule?.(name, true);
        } catch (loadErr) {
          replayDebug('ShapeVideoEncoder', `loadModule failed for ${name}: ${String(loadErr)}`);
        }
        const retried: ReplayEncoderNative | undefined = loader(name);
        if (isReplayEncoderNative(retried)) {
          replayInfo('ShapeVideoEncoder', `Successfully loaded module after loadModule: ${name}`);
          return retried;
        }
      }
    } else {
    }
  } catch (err) {
    replayWarn('ShapeVideoEncoder', 'Error in acquireReplayEncoder: ' + String(err));
  }
  return undefined;
}

// 这里定义一个简化接口：将 PixelMap 序列以 JPEG 图序列落盘，最后交给原生 AVCodec 组件二次封装（预留）。
// 为保持纯 ArkTS 可运行性，MVP 阶段暂以 MJPEG 近似：写入一连串 JPEG，最终由上层合并或仅作为 Debug 产物。

interface FileDirProvider { filesDir?: string; cacheDir?: string }
interface AbilityInfo { type?: string | number }
interface AbilityInfoProvider extends FileDirProvider { abilityInfo?: AbilityInfo }

class PixelMapSelectionImpl {
  public pixelMap: image.PixelMap;
  public fromSnapshot: boolean;

  constructor(pixelMap: image.PixelMap, fromSnapshot: boolean) {
    this.pixelMap = pixelMap;
    this.fromSnapshot = fromSnapshot;
  }
}

class SnapshotSizeRecord {
  public width: number;
  public height: number;

  constructor(width: number, height: number) {
    this.width = width;
    this.height = height;
  }
}

class SnapshotMetaRecord {
  public path: string;
  public width: number;
  public height: number;
  public stride: number;
  public pixelFormat: number;

  constructor(path: string, width: number, height: number, stride: number, pixelFormat: number) {
    this.path = path;
    this.width = width;
    this.height = height;
    this.stride = stride;
    this.pixelFormat = pixelFormat;
  }
}

interface PixelMapBufferReader {
  readPixelsToBuffer: (buffer: ArrayBuffer) => Promise<void>;
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

interface PositionArea {
  x: number;
  y: number;
  width: number;
  height: number;
}

interface PackingOptionWithArea extends image.PackingOption {
  area?: PositionArea;
  positionArea?: PositionArea;
}

class PixelBufferSelectionImpl {
  public buffer: ArrayBuffer;
  public stride: number;

  constructor(buffer: ArrayBuffer, stride: number) {
    this.buffer = buffer;
    this.stride = stride;
  }
}

interface SnapshotVariant {
  path: string;
  option: PackingOptionWithArea;
}

interface WindowStageHolder { windowStage?: Object }

interface WindowSnapshotSize {
  width: number;
  height: number;
}

interface WindowSnapshotOptions {
  imageSize?: WindowSnapshotSize;
}

interface AppStorageStatic {
  get: (key: string) => Object | undefined;
  setOrCreate?: (key: string, value: Object) => void;
}

interface GlobalWithAppStorage {
  AppStorage?: AppStorageStatic;
  __sentryReplayUiContext?: Object;
}

interface ComponentSnapshotOptions {
  width?: number;
  height?: number;
}

interface ComponentSnapshotAccessor {
  get?: (id: string | number, options?: ComponentSnapshotOptions) => image.PixelMap | Promise<image.PixelMap | undefined> | undefined;
}

interface UiContextLike {
  getHostContext?: () => common.UIAbilityContext | undefined;
  getComponentSnapshot?: () => ComponentSnapshotAccessor | undefined;
}

interface WindowSnapshotWithOptions {
  snapshot: (options: WindowSnapshotOptions) => Promise<image.PixelMap>;
}

export class ShapeVideoEncoder {
  private framesDir?: string; // 回退路径（仅调试）
  private frameCount: number = 0;
  private outputPath?: string;
  private fd: fs.File | undefined;
  private width: number = 720;
  private height: number = 1280;
  private fps: number = 2;
  private native?: ReplayEncoderNative;
  private ctx?: common.BaseContext;
  private baseContext?: common.BaseContext;
  private screenshotAvailable: boolean = true;
  private screenshotWarned: boolean = false;
  private activeWindow?: window.Window;
  private initializedWidth?: number;
  private initializedHeight?: number;
  private debugSnapshotDumped: boolean = false;
  private nativeRetryHandle?: number;
  private packerUnavailable: boolean = false;
  private positionAreaSupported: boolean = true;
  private storedUiContext?: UiContextLike;
  private hostContextAdopted: boolean = false;
  private rawFrameMode: boolean = false;
  private rawOnlyMode: boolean = false;
  private rawOnlyLogOnce: boolean = false;
  private bufferMode: boolean = false;
  private maxBufferDurationMs: number = 30000;
  private lastFrameTimestamp: number = -1;
  private virtualDuration: number = 0;
  private startTimeMs: number = 0;

  public setStartTime(ts: number): void {
    this.startTimeMs = ts;
  }

  public setBufferConfig(enabled: boolean, maxDurationMs: number): void {
    this.bufferMode = enabled;
    this.maxBufferDurationMs = maxDurationMs;
    if (enabled) {
      replayInfo('ShapeVideoEncoder', 'Buffer mode enabled, maxDuration=' + maxDurationMs + 'ms');
    }
  }

  public setWindow(win: window.Window | undefined): void {
    this.activeWindow = win;
    if (win) {
      this.screenshotAvailable = true;
      this.screenshotWarned = false;
    }
  }

  public enableRawOnlyMode(): void {
    if (this.rawOnlyMode) {
      return;
    }
    this.rawOnlyMode = true;
    this.rawFrameMode = true;
    this.framesDir = undefined;
    this.screenshotAvailable = false;
    this.screenshotWarned = false;
    this.rawOnlyLogOnce = false;
    try {
      replayInfo('ShapeVideoEncoder', 'raw-only mode enabled; snapshot fallback disabled');
    } catch (_) {}
  }

  private async obtainWindow(): Promise<window.Window | undefined> {
    if (this.activeWindow) {
      return this.activeWindow;
    }
    if (!this.ctx) {
      replayWarn('ShapeVideoEncoder', 'obtainWindow: ctx is undefined');
      return undefined;
    }
    try {
      const fetched = await window.getLastWindow(this.ctx);
      if (fetched) {
        this.activeWindow = fetched;
        this.screenshotAvailable = true;
        this.screenshotWarned = false;
        return fetched;
      } else {
        replayWarn('ShapeVideoEncoder', 'obtainWindow: getLastWindow returned undefined');
      }
    } catch (err) {
      if (!this.screenshotWarned) {
        this.screenshotWarned = true;
        replayWarn('ShapeVideoEncoder', 'getLastWindow failed: ' + String(err));
      }
    }
    return undefined;
  }

  public async captureSnapshot(): Promise<image.PixelMap | undefined> {
    // 只有在 ctx 未设置时才刷新上下文，避免覆盖已设置的上下文
    if (!this.ctx) {
    this.refreshContextFromStorage();
    }
    // 如果 ctx 仍然未设置，尝试从 baseContext 恢复
    if (!this.ctx && this.baseContext) {
      const effective = this.resolveEffectiveContext(this.baseContext);
      if (effective) {
        this.ctx = effective;
      }
    }
    if (!this.ctx) {
      replayWarn('ShapeVideoEncoder', 'captureSnapshot: ctx is undefined after refresh');
      return undefined;
    }
    const targetSize = this.computeSnapshotSize();
    const componentPrime = await this.captureRootComponentSnapshot(targetSize);
    if (componentPrime) {
      this.screenshotAvailable = true;
      this.screenshotWarned = false;
      return componentPrime;
    }

    const win = await this.obtainWindow();
    if (win) {
      try {
        const snapshotSize = targetSize;
        const snapshotOptions: WindowSnapshotOptions = { imageSize: snapshotSize };
        const snapshotWindow = win as Object as WindowSnapshotWithOptions;
        const pm = await snapshotWindow.snapshot(snapshotOptions);
        this.screenshotAvailable = true;
        this.screenshotWarned = false;
        try {
          const info: image.ImageInfo = await pm.getImageInfo();
          const fmtNum = typeof info.pixelFormat === 'number' ? info.pixelFormat : -1;
          const strideVal = typeof info.stride === 'number' ? info.stride : -1;
          const widthVal = info.size ? info.size.width : -1;
          const heightVal = info.size ? info.size.height : -1;
        } catch (infoErr) {
          replayWarn('ShapeVideoEncoder', 'snapshot info failed: ' + String(infoErr));
        }
        return pm;
      } catch (err) {
        replayWarn('ShapeVideoEncoder', 'window.snapshot failed: ' + String(err));
        this.activeWindow = undefined;
      }
    } else {
      replayWarn('ShapeVideoEncoder', 'captureSnapshot: obtainWindow returned undefined, ctx=' + (this.ctx ? 'defined' : 'undefined'));
    }
    replayWarn('ShapeVideoEncoder', 'captureSnapshot: componentSnapshot unavailable');
    return undefined;
  }

  private ensureNative(): boolean {
    if (this.native) {
      if (this.nativeRetryHandle !== undefined) {
        clearTimeout(this.nativeRetryHandle);
        this.nativeRetryHandle = undefined;
      }
      return true;
    }
    this.native = acquireReplayEncoder();
    if (!this.native && this.nativeRetryHandle === undefined) {
      this.nativeRetryHandle = setTimeout(() => {
        this.nativeRetryHandle = undefined;
        if (!this.native) {
          this.native = acquireReplayEncoder();
          if (this.native && this.nativeRetryHandle !== undefined) {
            clearTimeout(this.nativeRetryHandle);
            this.nativeRetryHandle = undefined;
          }
        }
      }, 200);
    }
    return !!this.native;
  }

  private resolveEffectiveContext(context: common.BaseContext): common.BaseContext {
    const storedUiContext = this.obtainStoredUiContext();
    if (storedUiContext && typeof storedUiContext.getHostContext === 'function') {
      const hostCtx = storedUiContext.getHostContext();
      if (hostCtx) {
        if (hostCtx !== context && !this.hostContextAdopted) {
          replayDebug('ShapeVideoEncoder', 'resolveEffectiveContext using host context from AppStorage');
          this.hostContextAdopted = true;
        }
        return hostCtx;
      }
    }
    return context;
  }

  private obtainStoredUiContext(): UiContextLike | undefined {
    try {
      const globalCandidate = globalThis as GlobalWithAppStorage;
      const storage = globalCandidate.AppStorage;
      if (!storage) {
        if (!this.storedUiContext) {
          const fallbackCandidate = this.adaptStoredUiContext(globalCandidate.__sentryReplayUiContext);
          if (fallbackCandidate) {
            this.storedUiContext = fallbackCandidate;
          }
        }
        return this.storedUiContext;
      }
      const stored = this.adaptStoredUiContext(storage.get(UI_CONTEXT_STORAGE_KEY));
      if (stored) {
        this.storedUiContext = stored;
        return this.storedUiContext;
      }
      if (!this.storedUiContext) {
        const fallbackFromGlobal = this.adaptStoredUiContext(globalCandidate.__sentryReplayUiContext);
        if (fallbackFromGlobal) {
          this.storedUiContext = fallbackFromGlobal;
          return this.storedUiContext;
        }
      }
    } catch (_) {}
    return this.storedUiContext;
  }

  private adaptStoredUiContext(candidate: Object | undefined): UiContextLike | undefined {
    if (!candidate) {
      return undefined;
    }
    try {
      const maybe = candidate as UiContextLike;
      if (typeof maybe.getHostContext === 'function' || typeof maybe.getComponentSnapshot === 'function') {
        return maybe;
      }
    } catch (_) {}
    try {
      const contextCandidate = candidate as common.BaseContext;
      if (contextCandidate && typeof contextCandidate === 'object') {
        return {
          getHostContext: () => contextCandidate as common.UIAbilityContext,
        } as UiContextLike;
      }
    } catch (_) {}
    return undefined;
  }

  private computeSnapshotSize(): WindowSnapshotSize {
    const targetWidth = this.width > 0 ? this.width : SNAPSHOT_MAX_WIDTH;
    const targetHeight = this.height > 0 ? this.height : SNAPSHOT_MAX_HEIGHT;
    const aspect = targetHeight > 0 ? targetWidth / targetHeight : (SNAPSHOT_MAX_WIDTH / SNAPSHOT_MAX_HEIGHT);
    let width = Math.min(SNAPSHOT_MAX_WIDTH, Math.max(SNAPSHOT_MIN_WIDTH, targetWidth));
    let height = Math.round(width / Math.max(aspect, 0.0001));
    if (height > SNAPSHOT_MAX_HEIGHT) {
      height = SNAPSHOT_MAX_HEIGHT;
      width = Math.round(height * aspect);
    }
    width = Math.max(SNAPSHOT_MIN_WIDTH, width);
    height = Math.max(SNAPSHOT_MIN_HEIGHT, height);
    return { width, height };
  }

  private refreshContextFromStorage(): void {
    if (!this.baseContext) {
      return;
    }
    const effective = this.resolveEffectiveContext(this.baseContext);
    // 只有在 effective 不为 undefined 时才更新 ctx，避免覆盖已设置的上下文
    if (effective && this.ctx !== effective) {
      this.ctx = effective;
    }
  }

  private async captureRootComponentSnapshot(targetSize?: WindowSnapshotSize): Promise<image.PixelMap | undefined> {
    const uiContext = this.obtainStoredUiContext();
    if (!uiContext) {
      replayWarn('ShapeVideoEncoder', 'captureRootComponentSnapshot: uiContext is undefined');
      return undefined;
    }
    const primary = await this.captureComponentSnapshot(uiContext, ROOT_COMPONENT_STRING_ID, targetSize);
    if (primary) {
      return primary;
    }
    return this.captureComponentSnapshot(uiContext, ROOT_COMPONENT_NUMERIC_ID, targetSize);
  }

  private async captureComponentSnapshot(uiContext: UiContextLike, componentId: string | number, targetSize?: WindowSnapshotSize): Promise<image.PixelMap | undefined> {
    try {
      if (typeof uiContext.getComponentSnapshot !== 'function') {
        return undefined;
      }
      const accessor = uiContext.getComponentSnapshot();
      if (!accessor || typeof accessor.get !== 'function') {
        return undefined;
      }
      const componentOptions = targetSize ? ({ width: targetSize.width, height: targetSize.height } as ComponentSnapshotOptions) : undefined;
      let candidate: image.PixelMap | Promise<image.PixelMap | undefined> | undefined;
      try {
        candidate = accessor.get(componentId, componentOptions);
      } catch (_) {
        candidate = accessor.get(componentId);
      }
      const resolved = await this.resolvePixelMapCandidate(candidate);
      if (resolved) {
      }
      return resolved;
    } catch (err) {
      replayWarn('ShapeVideoEncoder', 'component snapshot failed: ' + String(err));
      return undefined;
    }
  }

  private async resolvePixelMapCandidate(candidate: image.PixelMap | Promise<image.PixelMap | undefined> | undefined): Promise<image.PixelMap | undefined> {
    if (!candidate) {
      return undefined;
    }
    if (candidate instanceof Promise) {
      const resolved = await candidate;
      return resolved ? resolved : undefined;
    }
    return candidate;
  }

  public getOutputPath(): string | undefined { return this.outputPath; }
  public getOutputSize(): number | undefined {
    try {
      if (!this.outputPath) return undefined;
      const st = fs.statSync(this.outputPath);
      return (st && typeof st.size === 'number') ? (st.size as number) : undefined;
    } catch (_) { return undefined; }
  }

  public isInitialized(): boolean {
    return this.outputPath !== undefined && this.initializedWidth !== undefined && this.initializedHeight !== undefined;
  }

  public getInitializedWidth(): number {
    return this.initializedWidth ?? this.width;
  }

  public getInitializedHeight(): number {
    return this.initializedHeight ?? this.height;
  }

  public init(context: common.BaseContext, width: number = 720, height: number = 1280, fps: number = 2): void {
    // 如果编码器已经初始化，且分辨率不匹配，先清理旧的编码器
    if (this.isInitialized() &&
        (this.getInitializedWidth() !== width || this.getInitializedHeight() !== height)) {
      try {
        if (this.native) {
          this.native.finalize();
        }
        // 关闭文件描述符
        if (this.fd) {
          try {
            fs.close(this.fd.fd);
          } catch (_) {}
          this.fd = undefined;
        }
        // 清理状态
        this.outputPath = undefined;
        this.initializedWidth = undefined;
        this.initializedHeight = undefined;
      } catch (err) {
        replayWarn('ShapeVideoEncoder', 'init: failed to finalize old encoder: ' + String(err));
      }
    }

    this.baseContext = context;
    this.hostContextAdopted = false;
    this.lastFrameTimestamp = -1;
    this.virtualDuration = 0;
    const effectiveContext = this.resolveEffectiveContext(context);
    this.ctx = effectiveContext;
    this.width = width; this.height = height; this.fps = fps;
    this.screenshotAvailable = true;
    this.screenshotWarned = false;
    this.packerUnavailable = false;
    this.debugSnapshotDumped = false;
    this.positionAreaSupported = true;
    this.rawFrameMode = this.rawOnlyMode;
    const base = this.resolveBaseDir(effectiveContext);
    replayInfo('ShapeVideoEncoder', 'init baseDir=' + String(base) + ' rawOnly=' + String(this.rawOnlyMode)
      + ' ctxCtor=' + this.getConstructorName(effectiveContext));
    if (!base) return;

    this.ensureNative();
    const preferRawOnly = this.rawOnlyMode;
    if (!preferRawOnly && !this.isUiAbilityContext(effectiveContext)) {
      replayWarn('ShapeVideoEncoder', 'Non-UIAbility context detected, using ShapeVideoEncoder fallback');
      this.initFallback(base, width, height, fps);
      return;
    }
    // 在 rawOnlyMode 下，如果原生编码器不可用，应该立即失败，避免创建无效的视频文件
    if (preferRawOnly && !this.native) {
      replayWarn('ShapeVideoEncoder', 'encoder native module unavailable in raw-only mode, cannot initialize');
      this.outputPath = undefined;
      this.initializedWidth = undefined;
      this.initializedHeight = undefined;
      return;
    }
    const ts = Date.now();
    const mp4 = `${base}/replay_${ts}.mp4`;
    try {
      this.fd = fs.openSync(mp4, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      if (!this.native) {
        replayWarn('ShapeVideoEncoder', 'encoder native module missing, will use fallback');
        try { if (this.fd) { fs.close(this.fd.fd); } } catch (_) {}
        this.fd = undefined;
        this.initFallback(base, width, height, fps);
        return;
      }
      const ok = this.native.init(this.fd.fd, width, height, fps, 'video/avc');
      if (ok) {
        this.outputPath = mp4;
        this.initializedWidth = width;
        this.initializedHeight = height;
        this.debugSnapshotDumped = false;
        replayDebug('ShapeVideoEncoder', 'encoder init ok: ' + mp4 + ' ' + width + 'x' + height + '@' + fps);
        return;
      }
      if (preferRawOnly) {
        replayWarn('ShapeVideoEncoder', 'encoder init failed in raw-only mode, skip snapshot fallback');
        try { if (this.fd) { fs.close(this.fd.fd); } } catch (_) {}
        this.fd = undefined;
        this.outputPath = undefined;
        return;
      }
      replayDebug('ShapeVideoEncoder', 'encoder init failed, fallback will be used');
      try { if (this.fd) { fs.close(this.fd.fd); } } catch (_) {}
      this.fd = undefined;
    } catch (_) {}
    this.initFallback(base, width, height, fps);
  }

  private initFallback(base: string, width: number, height: number, fps: number): void {
    if (this.rawOnlyMode) {
      this.framesDir = undefined;
      try { replayWarn('ShapeVideoEncoder', 'initFallback skipped in raw-only mode'); } catch (_) {}
      return;
    }
    const ts = Date.now();
    const mp4 = `${base}/replay_${ts}.mp4`;
    try {
      this.fd = fs.openSync(mp4, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      if (!this.native) { 
        replayDebug('ShapeVideoEncoder', 'encoder native module missing');
      }
      const ok = this.native ? this.native.init(this.fd.fd, width, height, fps, 'video/avc') : false;
      if (ok) {
        this.outputPath = mp4;
        this.initializedWidth = width;
        this.initializedHeight = height;
        this.debugSnapshotDumped = false;
        replayDebug('ShapeVideoEncoder', 'encoder init ok: ' + mp4 + ' ' + width + 'x' + height + '@' + fps);
        return;
      }
      replayDebug('ShapeVideoEncoder', 'encoder init failed, fallback will be used');
      try { if (this.fd) { fs.close(this.fd.fd); } } catch (_) {}
      this.fd = undefined;
    } catch (_) {}
    const dir = `${base}/replay_frames`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
    } catch (_) {
      try { fs.mkdirSync(dir); } catch (ee) { replayWarn('ShapeVideoEncoder', 'mkdir failed: ' + String(ee)); }
    }
    this.framesDir = dir;
    this.initializedWidth = undefined;
    this.initializedHeight = undefined;
    this.debugSnapshotDumped = false;
    this.packerUnavailable = false;
    this.positionAreaSupported = true;
    this.rawFrameMode = this.rawOnlyMode;
    replayDebug('ShapeVideoEncoder', 'encoder fallback to jpeg dir: ' + dir);
  }

  private async resolvePixelMapForEncoding(pm: image.PixelMap): Promise<PixelMapSelectionImpl> {
    // 直接使用传入的 PixelMap，不再重复截图
    // ReplayController 已经负责调用 captureSnapshot 并传递了结果
    // 重复调用 captureSnapshot 会导致双倍开销，引起严重卡顿
    return new PixelMapSelectionImpl(pm, false);
  }

  public getInputWindow(): bigint | undefined {
    if (this.native && typeof this.native.getInputWindow === 'function') {
      return this.native.getInputWindow();
    }
    return undefined;
  }

  public async appendFrame(pm: image.PixelMap, timestampMs: number): Promise<void> {
    if (this.rawOnlyMode) {
      if (!this.rawOnlyLogOnce) {
        this.rawOnlyLogOnce = true;
        try { 
          replayDebug('ShapeVideoEncoder', 'appendFrame skipped due to raw-only mode'); 
        } catch (_) {}
      }
      return;
    }
    if (this.rawFrameMode) {
      return;
    }
    try {
      if (this.outputPath) {
        const selection: PixelMapSelectionImpl = await this.resolvePixelMapForEncoding(pm);
        const encodePm = selection.pixelMap;

        // Check and adjust dimensions if necessary
        try {
          const info = await encodePm.getImageInfo();
          const pmWidth = info.size ? info.size.width : 0;
          const pmHeight = info.size ? info.size.height : 0;

          if (pmWidth > 0 && pmHeight > 0 && this.isInitialized()) {
            // On first frame, determine target resolution (with downscaling for high-res screens)
            if (this.frameCount === 0 && this.ctx) {
              let targetW = pmWidth;
              let targetH = pmHeight;
              
              // Downscale if width > 720 to reduce file size
              if (targetW > 720) {
                targetW = targetW * 0.25;
                targetH = targetH * 0.25;
              }
              
              if (targetW > 720) {
                const scale = 720 / targetW;
                targetW = 720;
                targetH = targetH * scale;
              }
              
              // Ensure 16-pixel alignment for encoder compatibility
              targetW = Math.ceil(targetW / 16) * 16;
              targetH = Math.ceil(targetH / 16) * 16;
              
              const currentInitW = this.getInitializedWidth();
              const currentInitH = this.getInitializedHeight();
              
              if (targetW !== currentInitW || targetH !== currentInitH) {
                this.init(this.ctx, targetW, targetH, this.fps);
              }
            }

            const initW = this.getInitializedWidth();
            const initH = this.getInitializedHeight();

            if (pmWidth !== initW || pmHeight !== initH) {
              await encodePm.scale(initW / pmWidth, initH / pmHeight);
            }
          }
        } catch (dimErr) {
          replayWarn('ShapeVideoEncoder', 'appendFrame dimension check failed: ' + String(dimErr));
        }
        
        // 优先尝试使用 encodePixelMap 直接传递 PixelMap 给原生层
        // 这样可以避免在 ArkTS 层进行 readPixelsToBuffer，减少主线程开销
        if (this.native && typeof this.native.encodePixelMap === 'function') {
          if (this.lastFrameTimestamp < 0) {
            if (this.startTimeMs > 0 && timestampMs > this.startTimeMs) {
               this.virtualDuration = timestampMs - this.startTimeMs;
            } else {
               this.virtualDuration = 0;
            }
            this.lastFrameTimestamp = timestampMs;
          } else {
            let delta = timestampMs - this.lastFrameTimestamp;
            // 期望帧间隔（毫秒），允许少量误差
            const expectedInterval = 1000 / Math.max(1, this.fps);
            // 禁用时间戳压缩逻辑，以解决 QuickTime 和 Bilibili 等播放器时长不一致问题
            // 让 header 时长与 wall-clock 时长保持一致，确保文件对所有播放器有效
            if (delta < 0) delta = 0;
            this.virtualDuration += delta;
            this.lastFrameTimestamp = timestampMs;
          }
          const relativeTs = this.virtualDuration;

          const ok = this.native.encodePixelMap(encodePm, relativeTs);
          if (ok) {
            this.frameCount++;
          }
          
          if (selection.fromSnapshot) {
            try {
              interface Releasable { release?: () => void }
              const releasable = encodePm as Releasable;
              if (typeof releasable.release === 'function') { releasable.release(); }
            } catch (_) {}
          }
          return;
        }

        // 回退到旧逻辑：读取 Buffer
        const info = await encodePm.getImageInfo();
        const width = info.size ? (info.size.width as number) : this.width;
        const height = info.size ? (info.size.height as number) : this.height;
        const pixelFormat = typeof info.pixelFormat === 'number' ? info.pixelFormat : image.PixelMapFormat.UNKNOWN;
        const bytesPerPixel = this.resolveBytesPerPixel(pixelFormat);
        if (bytesPerPixel <= 0) {
          replayWarn('ShapeVideoEncoder', 'unsupported pixel format: ' + String(pixelFormat));
          return;
        }
        const strideReported = typeof info.stride === 'number' ? info.stride : -1;
        const expectedRowBytes = width * bytesPerPixel;
        let strideValue = this.resolveStride(info.stride, expectedRowBytes);
        const bufferSelection = await this.obtainPixelBuffer(encodePm, expectedRowBytes, height);
        if (!bufferSelection) {
          if (!this.debugSnapshotDumped) {
            this.debugSnapshotDumped = await this.dumpRawSnapshot(encodePm, 'buffer_unavailable');
          }
          return;
        }
        const rawBuffer: ArrayBuffer = bufferSelection.buffer;
        strideValue = bufferSelection.stride;
        let workingBuffer: ArrayBuffer = rawBuffer;
        if (strideValue !== expectedRowBytes && strideValue > expectedRowBytes) {
          workingBuffer = this.compactStride(rawBuffer, strideValue, expectedRowBytes, height);
        } else if (strideValue < expectedRowBytes) {
          replayWarn('ShapeVideoEncoder', 'unexpected stride: ' + String(strideValue) + ' < rowBytes: ' + String(expectedRowBytes));
          workingBuffer = rawBuffer;
        }
        workingBuffer = this.normalizeColorOrder(workingBuffer, expectedRowBytes, height, pixelFormat);
        if (selection.fromSnapshot && !this.debugSnapshotDumped) {
          this.debugSnapshotDumped = await this.dumpDebugSnapshot(selection.pixelMap, 'native');
        }
        if (this.native) {
          if (this.lastFrameTimestamp < 0) {
            this.lastFrameTimestamp = timestampMs;
            this.virtualDuration = 0;
          } else {
            let delta = timestampMs - this.lastFrameTimestamp;
            const expectedInterval = 1000 / Math.max(1, this.fps);
            // 暂时禁用时间戳压缩逻辑
            // if (delta > Math.max(5000, expectedInterval * 10)) {
            //   delta = expectedInterval;
            // }
            if (delta < 0) delta = 0;
            this.virtualDuration += delta;
            this.lastFrameTimestamp = timestampMs;
          }
          const relativeTs = this.virtualDuration;
          
          const ok = this.native.encode(workingBuffer, relativeTs);
        }
        if (selection.fromSnapshot) {
          try {
            interface Releasable { release?: () => void }
            const releasable = encodePm as Releasable;
            if (typeof releasable.release === 'function') { releasable.release(); }
          } catch (_) {}
        }
        return;
      }
      // 回退：优先复用 Screenshot 的保存路径（窗口截图），保证产物有效
      if (this.framesDir) {
        // 每帧写入前，确保目录存在（使用 fileio 更稳健）
        try { if (!fs.accessSync(this.framesDir)) { fs.mkdirSync(this.framesDir); } } catch (_) {}
        let filePath = `${this.framesDir}/f_${timestampMs}_${this.frameCount}.jpg`;
        try {
          // 直接窗口截图保存（完全复用 Screenshot 路线）
          if (!this.ctx) { throw new Error('no context for screenshot'); }
          if (!this.screenshotAvailable) { return; }
          
          const packer = image.createImagePacker();
          const opts: image.PackingOption = { format: 'image/jpeg', quality: 30 };
          const data = await packer.packing(pm, opts);
          // 使用异步文件IO避免阻塞主线程
          try {
            const file = await fs.open(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            await fileio.write(file.fd, data);
            await fs.close(file.fd);
            this.frameCount++;
            if (this.bufferMode) {
              this.pruneOldFrames(timestampMs);
            }
            replayDebug('ShapeVideoEncoder', 'frame saved to ' + filePath);
          } catch (ioErr) {
            replayWarn('ShapeVideoEncoder', 'file write failed: ' + String(ioErr));
          }
        } catch (err) {
          replayWarn('ShapeVideoEncoder', 'fallback frame capture failed: ' + String(err));
        }
        return;
      }

    } catch (err) {
      replayWarn('ShapeVideoEncoder', 'appendFrame error: ' + String(err));
      const fallbackWidth = this.initializedWidth ?? this.width;
      const fallbackHeight = this.initializedHeight ?? this.height;
      this.switchToFrameSequence(fallbackWidth, fallbackHeight);
    }
  }

  public appendRawFrame(
    buffer: ArrayBuffer,
    width: number,
    height: number,
    stride: number,
    timestampMs: number,
    encoderWidth?: number,
    encoderHeight?: number,
  ): void {
    try {
      this.enableRawOnlyMode();
      if (width <= 0 || height <= 0) {
        replayWarn('ShapeVideoEncoder', 'appendRawFrame invalid dimension: ' + String(width) + 'x' + String(height));
        return;
      }
      // 如果原生编码器不可用，尝试重新获取（最多重试3次）
      if (!this.native) {
        let retryCount = 0;
        const maxRetries = 3;
        while (!this.native && retryCount < maxRetries) {
          this.ensureNative();
          retryCount++;
        }
      }
      // 使用 encoderWidth/encoderHeight（对齐后的分辨率）来计算 buffer 大小
      // 这些值应该与 C++ 层的对齐逻辑一致
      let finalWidth = (encoderWidth && encoderWidth > 0) ? Math.floor(encoderWidth) : Math.floor(width);
      let finalHeight = (encoderHeight && encoderHeight > 0) ? Math.floor(encoderHeight) : Math.floor(height);

      // 应用与 C++ 层相同的对齐逻辑，确保 buffer 大小匹配
      // C++ 层会将分辨率对齐到 16 的倍数，且确保至少为 256
      const ALIGNMENT = 16;
      const MIN_SIZE = 256;
      const aspectRatio = (finalWidth > 0 && finalHeight > 0) ? finalWidth / finalHeight : 1.0;

      // 如果宽度或高度小于最小值，按比例放大
      if (finalWidth < MIN_SIZE && finalHeight < MIN_SIZE) {
        if (finalWidth >= finalHeight) {
          finalWidth = MIN_SIZE;
          finalHeight = Math.ceil(MIN_SIZE / aspectRatio);
        } else {
          finalHeight = MIN_SIZE;
          finalWidth = Math.ceil(MIN_SIZE * aspectRatio);
        }
      } else if (finalWidth < MIN_SIZE) {
        finalWidth = MIN_SIZE;
        finalHeight = Math.ceil(MIN_SIZE / aspectRatio);
      } else if (finalHeight < MIN_SIZE) {
        finalHeight = MIN_SIZE;
        finalWidth = Math.ceil(MIN_SIZE * aspectRatio);
      }

      // 对齐到 16 的倍数（与 C++ 层一致）
      finalWidth = Math.ceil(finalWidth / ALIGNMENT) * ALIGNMENT;
      finalHeight = Math.ceil(finalHeight / ALIGNMENT) * ALIGNMENT;

      if (!this.outputPath) {
        if (this.ctx) {
          this.init(this.ctx, finalWidth, finalHeight, this.fps);
        } else {
          replayWarn('ShapeVideoEncoder', 'appendRawFrame skipped: no context');
          return;
        }
      }
      if (!this.ensureNativeDimension(finalWidth, finalHeight)) {
        replayWarn('ShapeVideoEncoder', 'ensureNativeDimension failed: ' + String(finalWidth) + 'x' + String(finalHeight));
        return;
      }
      this.rawFrameMode = true;
      const bytesPerPixel = 4;
      // 计算对齐后的 stride（对齐到 64 字节）
      // 对于 RGBA 格式，stride = width * 4，但需要对齐到 64 字节
      const strideAlignmentBytes = 64; // 64 字节对齐
      const baseStrideBytes = finalWidth * bytesPerPixel;
      const alignedStrideBytes = Math.ceil(baseStrideBytes / strideAlignmentBytes) * strideAlignmentBytes;
      // 使用对齐后的 stride 计算 buffer 大小，以满足编码器的要求
      const expectedBufferSize = alignedStrideBytes * finalHeight;
      const expectedRowBytes = finalWidth * bytesPerPixel;
      let effectiveStride = stride > 0 ? stride : (Math.max(1, Math.floor(width)) * bytesPerPixel);
      let workingBuffer: ArrayBuffer = buffer;

      // 如果buffer大小小于所需大小，需要拉伸图像而不是填充
      if (buffer.byteLength < expectedBufferSize) {
        const src = new Uint8Array(buffer);
        const dst = new Uint8Array(expectedBufferSize);

        const originalWidth = Math.max(1, Math.floor(width));
        const originalHeight = Math.max(1, Math.floor(height));
        const originalRowBytes = originalWidth * bytesPerPixel;
        let originalStride = stride > 0 ? stride : originalRowBytes;
        if (originalStride <= 0) {
          originalStride = originalRowBytes;
        }

        // 使用双线性插值拉伸图像：从originalWidth x originalHeight拉伸到finalWidth x finalHeight
        const scaleX = (finalWidth > 1 && originalWidth > 1) ? (originalWidth - 1) / (finalWidth - 1) : (originalWidth / finalWidth);
        const scaleY = (finalHeight > 1 && originalHeight > 1) ? (originalHeight - 1) / (finalHeight - 1) : (originalHeight / finalHeight);

        for (let dstY = 0; dstY < finalHeight; dstY++) {
          const dstRowOffset = dstY * alignedStrideBytes;
          // 计算源图像中的Y坐标（使用浮点数进行插值）
          const srcY = dstY * scaleY;
          const srcY0 = Math.floor(srcY);
          const srcY1 = Math.min(srcY0 + 1, originalHeight - 1);
          const dy = srcY - srcY0;

          for (let dstX = 0; dstX < finalWidth; dstX++) {
            const dstColOffset = dstX * bytesPerPixel;
            // 计算源图像中的X坐标（使用浮点数进行插值）
            const srcX = dstX * scaleX;
            const srcX0 = Math.floor(srcX);
            const srcX1 = Math.min(srcX0 + 1, originalWidth - 1);
            const dx = srcX - srcX0;

            // 获取四个相邻像素
            const getPixel = (x: number, y: number): number[] => {
              const offset = y * originalStride + x * bytesPerPixel;
              if (offset >= 0 && offset + bytesPerPixel <= src.length) {
                return [src[offset], src[offset + 1], src[offset + 2], src[offset + 3]];
              }
              return [0, 0, 0, 255];
            };

            const p00 = getPixel(srcX0, srcY0);
            const p10 = getPixel(srcX1, srcY0);
            const p01 = getPixel(srcX0, srcY1);
            const p11 = getPixel(srcX1, srcY1);

            // 双线性插值
            const interpolate = (a: number, b: number, c: number, d: number, dx: number, dy: number): number => {
              const ab = a + (b - a) * dx;
              const cd = c + (d - c) * dx;
              return Math.round(ab + (cd - ab) * dy);
            };

            dst[dstRowOffset + dstColOffset] = interpolate(p00[0], p10[0], p01[0], p11[0], dx, dy);
            dst[dstRowOffset + dstColOffset + 1] = interpolate(p00[1], p10[1], p01[1], p11[1], dx, dy);
            dst[dstRowOffset + dstColOffset + 2] = interpolate(p00[2], p10[2], p01[2], p11[2], dx, dy);
            dst[dstRowOffset + dstColOffset + 3] = 255; // 强制alpha为255
          }
        }

        workingBuffer = dst.buffer as ArrayBuffer;
        effectiveStride = alignedStrideBytes;
        replayDebug('ShapeVideoEncoder', 'appendRawFrame buffer stretched: ' + String(buffer.byteLength) + ' -> ' + String(expectedBufferSize) + ' (original: ' + String(originalWidth) + 'x' + String(originalHeight) + ' -> ' + String(finalWidth) + 'x' + String(finalHeight) + ', alignedStride=' + String(alignedStrideBytes) + ')');
      } else if (buffer.byteLength > expectedBufferSize) {
        // Buffer 大于期望大小：需要缩放图像（从原始分辨率缩放到目标分辨率）
        // 使用最近邻插值进行快速缩放，避免双线性插值的计算开销
        const src = new Uint8Array(buffer);
        const dst = new Uint8Array(expectedBufferSize);

        const originalWidth = Math.max(1, Math.floor(width));
        const originalHeight = Math.max(1, Math.floor(height));
        const originalRowBytes = originalWidth * bytesPerPixel;
        let originalStride = stride > 0 ? stride : originalRowBytes;
        if (originalStride <= 0) {
          originalStride = originalRowBytes;
        }

        // 使用最近邻插值进行快速缩放（比双线性插值快得多）
        const scaleX = originalWidth / finalWidth;
        const scaleY = originalHeight / finalHeight;

        for (let dstY = 0; dstY < finalHeight; dstY++) {
          const dstRowOffset = dstY * alignedStrideBytes;
          const srcY = Math.floor(dstY * scaleY);
          const srcYClamped = Math.min(srcY, originalHeight - 1);

          for (let dstX = 0; dstX < finalWidth; dstX++) {
            const dstColOffset = dstX * bytesPerPixel;
            const srcX = Math.floor(dstX * scaleX);
            const srcXClamped = Math.min(srcX, originalWidth - 1);

            // 最近邻插值：直接复制最近的源像素
            const srcOffset = srcYClamped * originalStride + srcXClamped * bytesPerPixel;
            if (srcOffset >= 0 && srcOffset + bytesPerPixel <= src.length) {
              dst[dstRowOffset + dstColOffset] = src[srcOffset];
              dst[dstRowOffset + dstColOffset + 1] = src[srcOffset + 1];
              dst[dstRowOffset + dstColOffset + 2] = src[srcOffset + 2];
              dst[dstRowOffset + dstColOffset + 3] = src[srcOffset + 3];
            } else {
              // 边界情况：填充黑色
              dst[dstRowOffset + dstColOffset] = 0;
              dst[dstRowOffset + dstColOffset + 1] = 0;
              dst[dstRowOffset + dstColOffset + 2] = 0;
              dst[dstRowOffset + dstColOffset + 3] = 255;
            }
          }
        }

        workingBuffer = dst.buffer as ArrayBuffer;
        effectiveStride = alignedStrideBytes;
        replayDebug('ShapeVideoEncoder', 'appendRawFrame buffer scaled down (nearest neighbor): ' + String(buffer.byteLength) + ' -> ' + String(expectedBufferSize) + ' (original: ' + String(originalWidth) + 'x' + String(originalHeight) + ' -> ' + String(finalWidth) + 'x' + String(finalHeight) + ', alignedStride=' + String(alignedStrideBytes) + ')');
      } else if (effectiveStride > expectedRowBytes) {
        workingBuffer = this.compactStride(buffer, effectiveStride, expectedRowBytes, finalHeight);
        effectiveStride = expectedRowBytes;
      } else if (effectiveStride < expectedRowBytes) {
        replayWarn('ShapeVideoEncoder', 'appendRawFrame stride < rowBytes: ' + String(effectiveStride) + ' < ' + String(expectedRowBytes));
        return;
      }
      // Normalize color order if necessary (e.g., BGRA to RGBA)
      workingBuffer = this.normalizeColorOrder(workingBuffer, expectedRowBytes, finalHeight, image.PixelMapFormat.RGBA_8888);
      if (this.native) {
        const ok = this.native.encode(workingBuffer, timestampMs);
        replayDebug('ShapeVideoEncoder', 'encode raw frame ts=' + String(timestampMs) + ' ok=' + String(ok)
          + ', stride=' + String(effectiveStride) + ', size=' + String(finalWidth) + 'x' + String(finalHeight)
          + ', rawSize=' + String(width) + 'x' + String(height)
          + ', bufferBytes=' + String(buffer.byteLength) + ', expectedBufferSize=' + String(expectedBufferSize));
      } else {
        // 如果原生编码器为 null，尝试重新获取（最多重试3次）
        let retryCount = 0;
        const maxRetries = 3;
        while (!this.native && retryCount < maxRetries) {
          this.ensureNative();
          retryCount++;
        }
        // 显式类型检查，避免类型推断问题
        const nativeEncoder: ReplayEncoderNative | undefined = this.native;
        if (nativeEncoder !== undefined && nativeEncoder !== null) {
          // 重试成功，尝试编码
          const encoder: ReplayEncoderNative = nativeEncoder as ReplayEncoderNative;
          const ok: boolean = encoder.encode(workingBuffer, timestampMs);
          replayDebug('ShapeVideoEncoder', 'encode raw frame (after retry) ts=' + String(timestampMs) + ' ok=' + String(ok)
            + ', stride=' + String(effectiveStride) + ', size=' + String(finalWidth) + 'x' + String(finalHeight));
        } else {
          // 重试失败：如果处于 raw-only 模式，尝试回退到 JPEG 序列模式
          if (this.rawOnlyMode && this.ctx) {
            replayDebug('ShapeVideoEncoder', 'appendRawFrame: native encoder unavailable, switching to JPEG sequence mode');
            // 禁用 raw-only 模式，切换到 JPEG 序列模式
            this.rawOnlyMode = false;
            this.rawFrameMode = false;
            // 重新初始化编码器（使用 JPEG 序列模式）
            const base = this.resolveBaseDir(this.ctx);
            if (base) {
              this.initFallback(base, finalWidth, finalHeight, this.fps);
              // 尝试将 ArrayBuffer 转换为 PixelMap 并使用 appendFrame
              this.convertBufferToPixelMapAndAppend(workingBuffer, finalWidth, finalHeight, timestampMs).catch((err: Error | string) => {
                replayWarn('ShapeVideoEncoder', 'appendRawFrame: failed to convert buffer to PixelMap: ' + String(err));
              });
            }
          } else {
            // 记录警告（但不丢弃帧数据，因为可能后续会成功）
            if (this.frameCount % 10 === 0) { // 每10帧记录一次，避免日志过多
              replayWarn('ShapeVideoEncoder', 'appendRawFrame: native encoder is null after retries, frame will not be encoded. '
                + 'This may result in an invalid video file. Please ensure libreplay_encoder.z.so is available.');
            }
          }
        }
      }
      // 递增帧计数器（无论是否成功编码）
      this.frameCount++;
    } catch (err) {
      replayWarn('ShapeVideoEncoder', 'appendRawFrame error: ' + String(err));
    }
  }

  private pruneOldFrames(currentTimestampMs: number): void {
    if (!this.framesDir) return;
    try {
      const files = fs.listFileSync(this.framesDir);
      const limit = currentTimestampMs - this.maxBufferDurationMs;
      files.forEach((f: string) => {
        if (f.startsWith('f_') && f.endsWith('.jpg')) {
          // Format: f_{timestamp}_{count}.jpg
          const parts = f.split('_');
          if (parts.length >= 2) {
            const tsStr = parts[1];
            const ts = Number(tsStr);
            if (!isNaN(ts) && ts < limit) {
               try {
                 fs.unlinkSync(`${this.framesDir}/${f}`);
               } catch (_) {}
            }
          }
        }
      });
    } catch (e) {
      replayWarn('ShapeVideoEncoder', 'pruneOldFrames error: ' + String(e));
    }
  }

  public async finalize(context: common.BaseContext): Promise<string | undefined> {
    try {
      if (this.outputPath) {
        if (this.native) {
          try {
            this.native.finalize();
            // Patch MP4 duration metadata if needed (native encoder might write incorrect duration)
            if (this.outputPath && this.virtualDuration > 0) {
               try {
                 this.patchMp4Durations(this.outputPath, this.virtualDuration);
               } catch (patchErr) {
                 replayWarn('ShapeVideoEncoder', 'finalize: failed to patch MP4 duration: ' + String(patchErr));
               }
            }
          } catch (err) {
            replayWarn('ShapeVideoEncoder', 'native.finalize() error: ' + String(err));
          }
        }
        if (this.fd) {
          try {
            fs.close(this.fd.fd);
          } catch (_) {}
          this.fd = undefined;
        }
        try {
          const st = fs.statSync(this.outputPath);
          const size = st && typeof st.size === 'number' ? (st.size as number) : -1;
          // 如果文件太小（小于1KB），可能是无效的视频文件
          if (size < 1024) {
            replayWarn('ShapeVideoEncoder', 'finalize: video file is too small (' + String(size) + ' bytes), may be invalid. '
              + 'This usually means no frames were encoded. Please ensure libreplay_encoder.z.so is available.');
            // 删除无效的文件
            try {
              fs.unlinkSync(this.outputPath);
              replayInfo('ShapeVideoEncoder', 'finalize: deleted invalid video file: ' + this.outputPath);
              this.outputPath = undefined;
            } catch (unlinkErr) {
              replayWarn('ShapeVideoEncoder', 'finalize: failed to delete invalid video file: ' + String(unlinkErr));
            }
          } else {
          }
        } catch (statErr) {
          replayWarn('ShapeVideoEncoder', 'finalize: stat failed for ' + this.outputPath + ': ' + String(statErr));
        }
        const resultPath = this.outputPath;
        this.rawFrameMode = false;
        this.rawOnlyMode = false;
        this.rawOnlyLogOnce = false;
        this.frameCount = 0;
        return resultPath;
      }
    } catch (err) {
      replayWarn('ShapeVideoEncoder', 'finalize error: ' + String(err));
    }
    // 如果有 JPEG 序列目录，尝试使用 ffmpeg 合并成视频
    replayDebug('ShapeVideoEncoder', 'finalize: checking framesDir, framesDir=' + String(this.framesDir) + ', ctx=' + String(this.ctx ? 'present' : 'null'));
    if (this.framesDir && this.ctx) {
      try {
        // 检查目录中是否有 JPEG 文件
        const files = fs.listFileSync(this.framesDir);
        replayDebug('ShapeVideoEncoder', 'finalize: listed ' + String(files.length) + ' files in framesDir');
        const jpegFiles = files.filter((f: string) => {
          return f.endsWith('.jpg') || f.endsWith('.jpeg') || f.endsWith('.png');
        });
        replayDebug('ShapeVideoEncoder', 'finalize: filtered ' + String(jpegFiles.length) + ' JPEG files');
        
        if (jpegFiles.length > 0) {
          replayInfo('ShapeVideoEncoder', 'finalize: found ' + jpegFiles.length + ' JPEG frames, attempting to merge with ffmpeg');
          const ffmpegEncoder = new FfmpegVideoEncoder();
          const initializedWidth = this.getInitializedWidth();
          const initializedHeight = this.getInitializedHeight();
          ffmpegEncoder.init(this.ctx, this.framesDir, initializedWidth, initializedHeight, this.fps);
          const mergedVideoPath = await ffmpegEncoder.mergeFramesToVideo();
          if (mergedVideoPath) {
            // 更新 outputPath，以便 getOutputSize() 能正确返回文件大小
            this.outputPath = mergedVideoPath;
            replayInfo('ShapeVideoEncoder', 'finalize: ffmpeg merged video successfully: ' + mergedVideoPath);
            this.rawFrameMode = false;
            this.rawOnlyMode = false;
            this.rawOnlyLogOnce = false;
            this.frameCount = 0;
            return mergedVideoPath;
          } else {
            replayWarn('ShapeVideoEncoder', 'finalize: ffmpeg merge failed, returning JPEG frames directory: ' + this.framesDir);
          }
        }
      } catch (err) {
        replayWarn('ShapeVideoEncoder', 'finalize: ffmpeg merge error: ' + String(err));
      }
    }
    
    this.rawFrameMode = false;
    this.rawOnlyMode = false;
    this.rawOnlyLogOnce = false;
    this.frameCount = 0;
    return this.framesDir;
  }

  private resolveBaseDir(ctx: common.BaseContext): string | undefined {
    const p = ctx as AbilityInfoProvider;
    return p.filesDir ?? p.cacheDir;
  }

  private isUiAbilityContext(ctx: common.BaseContext): boolean {
    const provider = ctx as AbilityInfoProvider;
    const abilityInfo = provider.abilityInfo;
    let result = false;
    let typeDesc = 'undefined';
    const typeValue: string | number | undefined = abilityInfo ? abilityInfo.type : undefined;
    if (typeValue !== undefined) {
      typeDesc = String(typeValue) + '(' + typeof typeValue + ')';
      if (typeof typeValue === 'number') {
        result = typeValue === 1;
      } else if (typeof typeValue === 'string') {
        const normalized = typeValue.trim().toLowerCase();
        result = normalized === 'uiability' || normalized === 'ui' || normalized === '1';
      }
    }
    const ctorName = this.getConstructorName(ctx);
    if (!result && (ctorName === 'UIAbilityContext' || ctorName === 'AbilityContext')) {
      result = true;
    }
    let hasWindowStage = false;
    try {
      const stageHolder = ctx as WindowStageHolder;
      hasWindowStage = stageHolder !== undefined && stageHolder !== null
        && stageHolder.windowStage !== undefined && stageHolder.windowStage !== null;
      if (!result && hasWindowStage) {
        result = true;
      }
    } catch (_) {}
    let usedStoredUiContext = false;
    if (!result) {
      const storedUiContext = this.obtainStoredUiContext();
      if (storedUiContext && typeof storedUiContext.getHostContext === 'function') {
        const hostCtx = storedUiContext.getHostContext();
        if (hostCtx) {
          this.ctx = hostCtx;
          result = true;
          usedStoredUiContext = true;
        }
      }
    }
    replayDebug('ShapeVideoEncoder', 'isUiAbilityContext check: type=' + typeDesc
      + ', ctor=' + ctorName + ', hasWindowStage=' + String(hasWindowStage)
      + ', usedStoredUiContext=' + String(usedStoredUiContext) + ', result=' + String(result));
    return result;
  }

  private getConstructorName(target: Object | undefined): string {
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

  private resolveBytesPerPixel(format: image.PixelMapFormat): number {
    switch (format) {
      case image.PixelMapFormat.RGBA_8888:
      case image.PixelMapFormat.BGRA_8888:
      case image.PixelMapFormat.ARGB_8888:
        return 4;
      case image.PixelMapFormat.RGB_565:
        return 2;
      default:
        return 4;
    }
  }

  private resolveStride(stride: number, fallback: number): number {
    if (typeof stride === 'number' && stride > 0 && stride !== Infinity && stride !== -Infinity) {
      return stride;
    }
    return fallback;
  }

  private compactStride(buffer: ArrayBuffer, srcStride: number, dstStride: number, height: number): ArrayBuffer {
    const src = new Uint8Array(buffer);
    const total = dstStride * height;
    const dst = new Uint8Array(total);
    for (let row = 0; row < height; row++) {
      const srcOffset = row * srcStride;
      const dstOffset = row * dstStride;
      for (let col = 0; col < dstStride; col++) {
        dst[dstOffset + col] = src[srcOffset + col];
      }
    }
    replayDebug('ShapeVideoEncoder', 'compact stride: ' + String(srcStride) + ' -> ' + String(dstStride));
    return dst.buffer;
  }

  private ensureNativeDimension(actualWidth: number, actualHeight: number): boolean {
    if (actualWidth <= 0 || actualHeight <= 0) {
      return true;
    }
    if (!this.native) {
      this.initializedWidth = actualWidth;
      this.initializedHeight = actualHeight;
      return true;
    }
    if (this.initializedWidth === undefined || this.initializedHeight === undefined) {
      this.initializedWidth = actualWidth;
      this.initializedHeight = actualHeight;
      return true;
    }
    if (this.initializedWidth === actualWidth && this.initializedHeight === actualHeight) {
      return true;
    }
    // 在raw-only模式下，如果分辨率不匹配，重新初始化编码器
    if (this.rawOnlyMode && this.ctx) {
      replayWarn('ShapeVideoEncoder', 'dimension change detected in raw-only mode: ' + String(this.initializedWidth) + 'x' + String(this.initializedHeight)
        + ' -> ' + String(actualWidth) + 'x' + String(actualHeight) + ', reinitializing encoder');
      try {
        if (this.native) {
          this.native.finalize();
        }
      } catch (_) {}
      if (this.fd) {
        try { fs.close(this.fd.fd); } catch (_) {}
        this.fd = undefined;
      }
      this.outputPath = undefined;
      this.initializedWidth = undefined;
      this.initializedHeight = undefined;
      // 重新初始化编码器（使用对齐后的分辨率）
      this.init(this.ctx, actualWidth, actualHeight, this.fps);
      return true;
    }
    replayWarn('ShapeVideoEncoder', 'dimension change detected: ' + String(this.initializedWidth) + 'x' + String(this.initializedHeight)
      + ' -> ' + String(actualWidth) + 'x' + String(actualHeight) + ', switch to frame sequence');
    this.switchToFrameSequence(actualWidth, actualHeight);
      return false;
    }

  private switchToFrameSequence(width: number, height: number): void {
    const oldPath = this.outputPath;
    try {
      if (this.native) {
        this.native.finalize();
      }
    } catch (_) {}
    if (this.fd) {
      try { fs.close(this.fd.fd); } catch (_) {}
      this.fd = undefined;
    }
    if (oldPath) {
      try { fs.unlinkSync(oldPath); } catch (_) {}
    }
    this.outputPath = undefined;
    if (this.rawOnlyMode) {
      this.rawFrameMode = true;
      this.framesDir = undefined;
      this.initializedWidth = width;
      this.initializedHeight = height;
      this.debugSnapshotDumped = false;
      this.packerUnavailable = false;
      try { replayWarn('ShapeVideoEncoder', 'switchToFrameSequence skipped in raw-only mode'); } catch (_) {}
      return;
    }
    this.rawFrameMode = false;
    if (!this.ctx) {
      this.initializedWidth = width;
      this.initializedHeight = height;
      this.debugSnapshotDumped = false;
      return;
    }
    const base = this.resolveBaseDir(this.ctx);
    if (!base) {
      this.initializedWidth = width;
      this.initializedHeight = height;
      this.debugSnapshotDumped = false;
      return;
    }
    const dir = `${base}/replay_frames`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
    } catch (_) {
      try { fs.mkdirSync(dir); } catch (ee) { replayWarn('ShapeVideoEncoder', 'mkdir failed (frame sequence): ' + String(ee)); }
    }
    this.framesDir = dir;
    this.initializedWidth = width;
    this.initializedHeight = height;
    this.debugSnapshotDumped = false;
    this.packerUnavailable = false;
    replayDebug('ShapeVideoEncoder', 'switch to frame sequence dir=' + dir + ' size=' + String(width) + 'x' + String(height));
  }

  // 将 ArrayBuffer 转换为 PixelMap 并调用 appendFrame（用于回退到 JPEG 序列模式）
  private async convertBufferToPixelMapAndAppend(
    buffer: ArrayBuffer,
    width: number,
    height: number,
    timestampMs: number
  ): Promise<void> {
    try {
      // 使用 createPixelMap 从 ArrayBuffer 创建 PixelMap
      const opts: image.InitializationOptions = {
        size: { width: width, height: height },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        alphaType: 1, // UNPREMUL
        editable: false
      } as image.InitializationOptions;
      
      const pixelMap = await image.createPixelMap(buffer, opts);
      if (pixelMap) {
        await this.appendFrame(pixelMap, timestampMs);
      }
    } catch (err) {
      replayWarn('ShapeVideoEncoder', 'convertBufferToPixelMapAndAppend failed: ' + String(err));
    }
  }

  private normalizeColorOrder(buffer: ArrayBuffer, rowBytes: number, height: number, format: image.PixelMapFormat): ArrayBuffer {
    if (rowBytes <= 0 || height <= 0) {
      return buffer;
    }
    if (format === image.PixelMapFormat.RGBA_8888) {
      return buffer;
    }
    if (format !== image.PixelMapFormat.BGRA_8888 && format !== image.PixelMapFormat.ARGB_8888) {
      return buffer;
    }
    const total = rowBytes * height;
    const src = new Uint8Array(buffer, 0, total);
    const dst = new Uint8Array(total);
    const step = 4;
    for (let i = 0; i < total; i += step) {
      const a0 = src[i];
      const a1 = src[i + 1];
      const a2 = src[i + 2];
      const a3 = src[i + 3];
      if (format === image.PixelMapFormat.BGRA_8888) {
        dst[i] = a2;
        dst[i + 1] = a1;
        dst[i + 2] = a0;
        dst[i + 3] = a3;
      } else {
        dst[i] = a1;
        dst[i + 1] = a2;
        dst[i + 2] = a3;
        dst[i + 3] = a0;
      }
    }
    replayDebug('ShapeVideoEncoder', 'normalize color order format=' + String(format));
    return dst.buffer;
  }

  private async dumpDebugSnapshot(pm: image.PixelMap, prefix: string): Promise<boolean> {
    try {
      if (!this.ctx) {
        return false;
      }
      const base = this.resolveBaseDir(this.ctx);
      if (!base) {
        return false;
      }
      const info = await pm.getImageInfo();
      const debugArea = this.buildFullArea((info.size?.width as number) ?? 0, (info.size?.height as number) ?? 0);
      if (this.packerUnavailable) {
        return await this.dumpRawSnapshot(pm, prefix + '_packer_unavailable');
      }
      const ts = Date.now();
      const variants: Array<SnapshotVariant> = [
        { path: `${base}/replay_debug_${prefix}_${ts}.png`, option: this.createPackingOption('image/png', 100, debugArea) },
        { path: `${base}/replay_debug_${prefix}_${ts}.jpg`, option: this.createPackingOption('image/jpeg', 80, debugArea) }
      ];
      const savedPath = await this.saveSnapshotWithPacker(pm, variants);
      if (savedPath) {
        try {
          const st = fs.statSync(savedPath);
          replayDebug('ShapeVideoEncoder', 'dump debug snapshot: ' + savedPath + ' bytes=' + String(st?.size ?? 0));
        } catch (_) {}
        return true;
      }
      this.packerUnavailable = true;
      return await this.dumpRawSnapshot(pm, prefix + '_raw');
    } catch (err) {
      this.packerUnavailable = true;
      replayWarn('ShapeVideoEncoder', 'dump debug snapshot failed: ' + String(err));
      return this.dumpRawSnapshot(pm, prefix + '_raw');
    }
  }

  private async dumpRawSnapshot(pm: image.PixelMap, prefix: string): Promise<boolean> {
    try {
      if (!this.ctx) {
        return false;
      }
      const base = this.resolveBaseDir(this.ctx);
      if (!base) {
        return false;
      }
      const info = await pm.getImageInfo();
      const width = info.size ? (info.size.width as number) : 0;
      const height = info.size ? (info.size.height as number) : 0;
      const pixelFormat = typeof info.pixelFormat === 'number' ? info.pixelFormat : image.PixelMapFormat.UNKNOWN;
      const strideReported = typeof info.stride === 'number' ? info.stride : -1;
      replayDebug('ShapeVideoEncoder', 'dumpRawSnapshot info fmt=' + String(pixelFormat) + ', strideReported=' + String(strideReported)
        + ', width=' + String(width) + ', height=' + String(height));
      const bytesPerPixel = this.resolveBytesPerPixel(pixelFormat);
      if (bytesPerPixel <= 0) {
        return false;
      }
      let strideValue = this.resolveStride(info.stride, width * bytesPerPixel);
      const bufferSelection = await this.obtainPixelBuffer(pm, width * bytesPerPixel, height);
      if (!bufferSelection) {
        return false;
      }
      const buffer = bufferSelection.buffer;
      strideValue = bufferSelection.stride;
      const ts = Date.now();
      const rawPath = `${base}/replay_debug_${prefix}_${ts}.rgba`;
      const O_CREAT = 0o100; const O_RDWR = 0o2;
      const fd = fileio.openSync(rawPath, O_CREAT | O_RDWR, 0o666);
      const data = new Uint8Array(buffer);
      if (data.byteLength > 0) { fileio.writeSync(fd, data); }
      fileio.closeSync(fd);
      const meta = new SnapshotMetaRecord(rawPath, width, height, strideValue, pixelFormat);
      const metaJson = JSON.stringify(meta);
      const metaBytes = this.encodeUtf8(metaJson);
      const metaPath = `${base}/replay_debug_${prefix}_${ts}.json`;
      const mfd = fileio.openSync(metaPath, O_CREAT | O_RDWR, 0o666);
      if (metaBytes.length > 0) { fileio.writeSync(mfd, metaBytes); }
      fileio.closeSync(mfd);
      replayDebug('ShapeVideoEncoder', 'dump raw snapshot: ' + rawPath + ' bytes=' + String(data.byteLength)
        + ', stride=' + String(strideValue));
      return true;
    } catch (err) {
      replayWarn('ShapeVideoEncoder', 'dump raw snapshot failed: ' + String(err));
      return false;
    }
  }

  private encodeUtf8(text: string): Uint8Array {
    const length = text.length;
    const out = new Uint8Array(length);
    for (let i = 0; i < length; i++) {
      out[i] = text.charCodeAt(i) & 0xFF;
    }
    return out;
  }

  private resolveStrideFromTotal(totalBytes: number, expectedRowBytes: number, rows: number): number {
    if (rows <= 0 || totalBytes <= 0) {
      return expectedRowBytes;
    }
    const approxStride = Math.floor(totalBytes / rows);
    if (approxStride >= expectedRowBytes) {
      return approxStride;
    }
    return expectedRowBytes;
  }

  private async obtainPixelBuffer(pm: image.PixelMap, expectedRowBytes: number, height: number): Promise<PixelBufferSelectionImpl | undefined> {
    const rows = Math.max(1, height);
    const bufferReader = pm as PixelMapBufferReader;
    if (bufferReader && typeof bufferReader.readPixelsToBuffer === 'function' && bufferReader.readPixelsToBuffer.length === 1) {
      const buffer = new ArrayBuffer(Math.max(1, expectedRowBytes) * rows);
      try {
        await bufferReader.readPixelsToBuffer(buffer);
        if (buffer && buffer.byteLength > 0) {
          const stride = this.resolveStrideFromTotal(buffer.byteLength, expectedRowBytes, rows);
          return new PixelBufferSelectionImpl(buffer, stride);
        }
      } catch (err) {
        const message = String(err);
        replayWarn('ShapeVideoEncoder', 'readPixels(buffer) failed: ' + message);
        if (this.positionAreaSupported && message.indexOf('position area') >= 0) {
          this.positionAreaSupported = false;
          replayWarn('ShapeVideoEncoder', 'position area unsupported during buffer read, disabling area placement');
        }
      }
    }
    const legacyReader = pm as PixelMapLegacyReader;
    if (legacyReader && typeof legacyReader.readPixelsToBuffer === 'function' && legacyReader.readPixelsToBuffer.length >= 2) {
      const buffer = new ArrayBuffer(Math.max(1, expectedRowBytes) * rows);
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
          const stride = this.resolveStrideFromTotal(buffer.byteLength, expectedRowBytes, rows);
          return new PixelBufferSelectionImpl(buffer, stride);
        }
      } catch (err) {
        const message = String(err);
        replayWarn('ShapeVideoEncoder', 'readPixels(legacy) failed: ' + message);
        if (this.positionAreaSupported && message.indexOf('position area') >= 0) {
          this.positionAreaSupported = false;
          replayWarn('ShapeVideoEncoder', 'position area unsupported during legacy read, disabling area placement');
        }
      }
    }
    return undefined;
  }

  private createPackingOption(format: string, quality: number, area?: PositionArea): PackingOptionWithArea {
    const option = { format: format, quality: quality } as PackingOptionWithArea;
    if (this.positionAreaSupported && area && area.width > 0 && area.height > 0) {
      option.area = area;
      option.positionArea = area;
    }
    return option;
  }

  private async saveSnapshotWithPacker(pm: image.PixelMap, variants: Array<SnapshotVariant>): Promise<string | undefined> {
    let packer: image.ImagePacker | undefined;
    for (let i = 0; i < variants.length; i++) {
      const variant = variants[i];
      const O_CREAT = 0o100; const O_RDWR = 0o2; const O_TRUNC = 0o1000;
      if (!packer) {
        try {
          packer = image.createImagePacker();
        } catch (createErr) {
          replayWarn('ShapeVideoEncoder', 'createImagePacker failed: ' + String(createErr));
          continue;
        }
      }
      const attempts: Array<PackingOptionWithArea> = this.buildPackingAttempts(variant.option);
      for (let attemptIndex = 0; attemptIndex < attempts.length; attemptIndex++) {
        const attemptOption = attempts[attemptIndex];
        let fd: number | undefined;
        try {
          fd = fileio.openSync(variant.path, O_CREAT | O_RDWR | O_TRUNC, 0o666);
          replayDebug('ShapeVideoEncoder', 'packToFile attempt: path=' + variant.path
            + ', attempt=' + String(attemptIndex + 1)
            + ', option=' + this.describePackingOption(attemptOption));
          await packer.packToFile(pm, fd, attemptOption);
          fileio.closeSync(fd); fd = undefined;
          const st = fs.statSync(variant.path);
          const size = st && typeof st.size === 'number' ? (st.size as number) : 0;
          replayDebug('ShapeVideoEncoder', 'packToFile result: path=' + variant.path + ' bytes=' + String(size));
          if (size > 0) {
            return variant.path;
          }
        } catch (err) {
          const errMsg = String(err);
          const areaError = errMsg.indexOf('position area') >= 0;
          if (areaError) {
            if (this.positionAreaSupported) {
              this.positionAreaSupported = false;
              replayWarn('ShapeVideoEncoder', 'packToFile failed due to position area, disabling area support. err=' + errMsg
                + ' path=' + variant.path + ', option=' + this.describePackingOption(attemptOption));
            } else {
              replayDebug('ShapeVideoEncoder', 'packToFile position area error (area already disabled): ' + errMsg
                + ' path=' + variant.path + ', option=' + this.describePackingOption(attemptOption));
            }
          } else {
            replayWarn('ShapeVideoEncoder', 'packToFile failed: ' + errMsg + ' path=' + variant.path
              + ', option=' + this.describePackingOption(attemptOption));
          }
        } finally {
          if (fd !== undefined) {
            try { fileio.closeSync(fd); } catch (_) {}
          }
        }
        try { fs.unlinkSync(variant.path); } catch (_) {}
      }
      try {
        const fallbackOption = attempts.length > 1 ? attempts[attempts.length - 1] : attempts[0];
        replayDebug('ShapeVideoEncoder', 'packToFile fallback: using packing() path=' + variant.path
          + ', option=' + this.describePackingOption(fallbackOption));
        const buffer = await packer.packing(pm, fallbackOption);
        if (buffer && buffer.byteLength > 0) {
          const fd = fileio.openSync(variant.path, O_CREAT | O_RDWR | O_TRUNC, 0o666);
          try {
            const data = new Uint8Array(buffer);
            if (data.byteLength > 0) {
              fileio.writeSync(fd, data);
            }
          } finally {
            fileio.closeSync(fd);
          }
          const st = fs.statSync(variant.path);
          const size = st && typeof st.size === 'number' ? (st.size as number) : 0;
          replayDebug('ShapeVideoEncoder', 'packing fallback result: path=' + variant.path + ' bytes=' + String(size));
          if (size > 0) {
            return variant.path;
          }
        }
      } catch (packErr) {
        replayWarn('ShapeVideoEncoder', 'packing fallback failed: ' + String(packErr) + ' path=' + variant.path);
      }
      try { fs.unlinkSync(variant.path); } catch (_) {}
    }
    return undefined;
  }

  private buildPackingAttempts(option: PackingOptionWithArea): Array<PackingOptionWithArea> {
    const attempts: Array<PackingOptionWithArea> = [];
    const originalHasArea = (option.area !== undefined && option.area !== null)
      || (option.positionArea !== undefined && option.positionArea !== null);
    const primary = this.sanitizePackingOption(option, this.positionAreaSupported);
    const primaryHasArea = (primary.area !== undefined && primary.area !== null)
      || (primary.positionArea !== undefined && primary.positionArea !== null);
    if (!this.positionAreaSupported && originalHasArea) {
      replayDebug('ShapeVideoEncoder', 'buildPackingAttempts: area stripped due to unsupported API');
    }
    attempts.push(primary);
    if (primaryHasArea) {
      const fallbackOption = this.sanitizePackingOption(option, false);
      attempts.push(fallbackOption);
    }
    return attempts;
  }

  private sanitizePackingOption(option: PackingOptionWithArea, allowArea: boolean): PackingOptionWithArea {
    const sanitized = { format: option.format, quality: option.quality } as PackingOptionWithArea;
    if (allowArea) {
      const area = option.positionArea ?? option.area;
      if (area && area.width > 0 && area.height > 0) {
        sanitized.area = area;
        sanitized.positionArea = area;
      }
    }
    return sanitized;
  }

  private describePackingOption(option: PackingOptionWithArea): string {
    try {
      const fmt = option && option.format ? String(option.format) : 'undefined';
      const qualityValue = option && option.quality !== undefined ? String(option.quality) : 'default';
      const chosenArea = option.positionArea ?? option.area;
      const areaDesc = chosenArea ? (String(chosenArea.x) + ',' + String(chosenArea.y) + ','
        + String(chosenArea.width) + 'x' + String(chosenArea.height)) : 'none';
      return 'format=' + fmt + ', quality=' + qualityValue + ', area=' + areaDesc;
    } catch (_) {
      return 'format=' + String(option?.format) + ', quality=' + String(option?.quality);
    }
  }

  private buildFullArea(width: number, height: number): PositionArea | undefined {
    if (width > 0 && height > 0) {
      return { x: 0, y: 0, width: width, height: height } as PositionArea;
    }
    return undefined;
  }

  private patchMp4Durations(path: string, durationMs: number): void {
    if (!path || durationMs <= 0) return;
    let file: fs.File | undefined;
    try {
      const st = fs.statSync(path);
      const size = st && typeof st.size === 'number' ? (st.size as number) : 0;
      if (size < 1024) return; // too small
      
      file = fs.openSync(path, fs.OpenMode.READ_WRITE);
      const buffer = new ArrayBuffer(1024 * 1024); // Read first 1MB
      const readLen = fs.readSync(file.fd, buffer);
      if (readLen < 64) return;
      
      const bytes = new Uint8Array(buffer, 0, readLen);
      let mvhdPos = this.findFourcc(bytes, 'mvhd');
      let fileOffset = 0;
      let targetBytes = bytes;

      // If not found in head, try searching in tail
      if (mvhdPos < 0 && size > 1024 * 1024) {
        const tailSize = 512 * 1024;
        const offset = Math.max(0, size - tailSize);
        const tailBuffer = new ArrayBuffer(tailSize);
        const tailReadLen = fs.readSync(file.fd, tailBuffer, { offset: offset });
        if (tailReadLen > 64) {
           const tailBytes = new Uint8Array(tailBuffer, 0, tailReadLen);
           const tailPos = this.findFourcc(tailBytes, 'mvhd');
           if (tailPos >= 0) {
             mvhdPos = tailPos;
             fileOffset = offset;
             targetBytes = tailBytes;
           }
        }
      }

      if (mvhdPos >= 0) {
        const ver = targetBytes[mvhdPos + 4];
        if (ver === 0) {
          const timescale = this.readUint32BE(targetBytes, mvhdPos + 16);
          if (timescale > 0) {
            const newDuration = Math.floor((durationMs * timescale) / 1000);
            this.writeUint32BE(targetBytes, mvhdPos + 20, newDuration);
            fs.writeSync(file.fd, targetBytes.buffer, { offset: fileOffset, length: targetBytes.length });
          }
        } else if (ver === 1) {
          const timescale = this.readUint32BE(targetBytes, mvhdPos + 20);
          if (timescale > 0) {
            const newDuration = BigInt(Math.floor((durationMs * timescale) / 1000));
            this.writeUint64BE(targetBytes, mvhdPos + 24, newDuration);
            fs.writeSync(file.fd, targetBytes.buffer, { offset: fileOffset, length: targetBytes.length });
          }
        }
      }
    } catch (e) {
      replayWarn('ShapeVideoEncoder', 'patchMp4Durations failed: ' + String(e));
    } finally {
      if (file) {
        try { fs.closeSync(file); } catch (_) {}
      }
    }
  }

  private findFourcc(buf: Uint8Array, fourcc: string): number {
    if (buf.length < 4) return -1;
    const c0 = fourcc.charCodeAt(0);
    const c1 = fourcc.charCodeAt(1);
    const c2 = fourcc.charCodeAt(2);
    const c3 = fourcc.charCodeAt(3);
    for (let i = 0; i <= buf.length - 4; i++) {
      if (buf[i] === c0 && buf[i+1] === c1 && buf[i+2] === c2 && buf[i+3] === c3) {
        return i;
      }
    }
    return -1;
  }

  private readUint32BE(buf: Uint8Array, offset: number): number {
    return ((buf[offset] & 0xFF) * 16777216) + ((buf[offset+1] & 0xFF) << 16) + ((buf[offset+2] & 0xFF) << 8) + (buf[offset+3] & 0xFF);
  }

  private writeUint32BE(buf: Uint8Array, offset: number, val: number): void {
    buf[offset] = (val >>> 24) & 0xff;
    buf[offset+1] = (val >>> 16) & 0xff;
    buf[offset+2] = (val >>> 8) & 0xff;
    buf[offset+3] = val & 0xff;
  }

  private writeUint64BE(buf: Uint8Array, offset: number, val: bigint): void {
    const high = Number((val >> 32n) & 0xFFFFFFFFn);
    const low = Number(val & 0xFFFFFFFFn);
    this.writeUint32BE(buf, offset, high);
    this.writeUint32BE(buf, offset + 4, low);
  }

}


