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
import common from '@ohos.app.ability.common';
import media from '@ohos.multimedia.media';
import type drawing from '@ohos.graphics.drawing';
import { ShapeVideoEncoder } from './ShapeVideoEncoder';
import { replayInfo, replayWarn, replayError, replayDebug } from './ReplayLogger';
import window from '@ohos.window';

// ArkTS 版视频编码器实现：
// - 优先使用 AVRecorder Surface 模式（需要 gfxSurface API）
// - 备用方案：使用 MediaCodec Buffer 模式（基于华为开发者文档的最佳实践）
// - 最终回退：ShapeVideoEncoder（JPEG/原生兜底）
// 本地最小 Surface 类型声明与 API（避免依赖 SDK 模块导入）
interface SurfaceFrame { getCanvas(): drawing.Canvas }
interface Surface { requestFrame(width: number, height: number): Promise<SurfaceFrame>; flushFrame(frame: SurfaceFrame): Promise<void> }
interface SurfaceApi { createSurfaceFromId(id: string): Promise<Surface> }
// 运行时从 globalThis 提取，若不可用将导致初始化失败并回退至 JPEG 兜底
interface GlobalWithSurface { gfxSurface?: SurfaceApi }
function getSurfaceApi(): SurfaceApi | undefined {
  const g = (globalThis as GlobalWithSurface);
  const api = g.gfxSurface;
  return api as SurfaceApi | undefined;
}

export class ArkTsVideoEncoder {
  private delegate: ShapeVideoEncoder = new ShapeVideoEncoder();
  // AVRecorder 管线
  private recorder?: media.AVRecorder;
  private inputSurface?: Surface;
  private outputPath?: string;
  private fd: fs.File | undefined;
  private width: number = 720;
  private height: number = 1280;
  private fps: number = 2;
  private setupPromise?: Promise<void>;
  private latestWindow?: window.Window;
  private bufferMode: boolean = false;

  public setBufferConfig(enabled: boolean, maxDurationMs: number): void {
    this.bufferMode = enabled;
    this.delegate.setBufferConfig(enabled, maxDurationMs);
  }

  public setStartTime(ts: number): void {
    this.delegate.setStartTime(ts);
  }

  public init(context: common.BaseContext, width: number = 720, height: number = 1280, fps: number = 2): void {
    this.width = width; this.height = height; this.fps = fps;
    // 无论 setupRecorderPipeline 成功与否，都需要设置 delegate 的上下文
    // 因为 captureSnapshot() 会调用 delegate.captureSnapshot()，需要 ctx
    this.delegate.init(context, width, height, fps);
    if (this.latestWindow) {
      this.delegate.setWindow(this.latestWindow);
    }
    this.setupPromise = this.setupRecorderPipeline(context).catch((err: Error) => {
      replayWarn('ArkTsVideoEncoder', 'AVRecorder setup failed, fallback to ShapeVideoEncoder (JPEG sequence). err=' + (err?.message ?? String(err)));
      // 不要启用 raw-only 模式，让 ShapeVideoEncoder 使用 JPEG 序列作为备用方案
    });
  }

  private async setupRecorderPipeline(context: common.BaseContext): Promise<void> {
    replayInfo('ArkTsVideoEncoder', 'setupRecorderPipeline start');
    try {
    const base = this.resolveBaseDir(context);
    if (!base) { throw new Error('no base dir'); }
    const mp4 = `${base}/replay_${Date.now()}.mp4`;
    try {
      this.fd = fs.openSync(mp4, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      this.outputPath = mp4;
      const fdNum: number = (this.fd as fs.File).fd;

      const rec = await media.createAVRecorder();
      // 根据华为开发者文档的最佳实践优化配置
      // 1. 使用合适的码率（根据分辨率和帧率计算）
      // 2. 确保分辨率对齐到编码器要求（16的倍数）
      const alignedWidth = Math.ceil(this.width / 16) * 16;
      const alignedHeight = Math.ceil(this.height / 16) * 16;
      // 码率计算：根据分辨率和帧率，使用经验公式 bitrate = width * height * fps * 0.1
      const calculatedBitrate = Math.max(500_000, Math.min(10_000_000, alignedWidth * alignedHeight * this.fps * 0.1));

      const config: media.AVRecorderConfig = {
        videoSourceType: media.VideoSourceType.VIDEO_SOURCE_TYPE_SURFACE_YUV,
        profile: {
          fileFormat: media.ContainerFormatType.CFT_MPEG_4,
          videoCodec: media.CodecMimeType.VIDEO_AVC,
          videoFrameWidth: alignedWidth,
          videoFrameHeight: alignedHeight,
          videoFrameRate: this.fps,
          videoBitrate: calculatedBitrate
        },
        url: `fd://${fdNum}`
      } as media.AVRecorderConfig;

      replayDebug('ArkTsVideoEncoder', 'AVRecorder config: ' + alignedWidth + 'x' + alignedHeight
        + '@' + this.fps + 'fps, bitrate=' + calculatedBitrate);

      await rec.prepare(config);
      const surfaceId = await rec.getInputSurface();
        const surfaceApi = getSurfaceApi();
        if (!surfaceApi) {
          throw new Error('surface api unavailable');
        }
      const surf = await surfaceApi.createSurfaceFromId(surfaceId);
      this.recorder = rec;
      this.inputSurface = surf;
      replayInfo('ArkTsVideoEncoder', 'AVRecorder prepared. path=' + mp4 + ', w=' + String(this.width) + ', h=' + String(this.height) + ', fps=' + String(this.fps));
      replayInfo('ArkTsVideoEncoder', 'AVRecorder input surface id=' + surfaceId);
      await rec.start();
      replayInfo('ArkTsVideoEncoder', 'AVRecorder started');
        return;
    } catch (e) {
      // 清理半成品文件并抛出，让上层回退到 JPEG
        try { if (this.recorder) { await this.recorder.stop(); } } catch (_) {}
        try { if (this.recorder) { await this.recorder.release(); } } catch (_) {}
        this.recorder = undefined;
        this.inputSurface = undefined;
      try { if (this.fd) { fs.close((this.fd as fs.File).fd); } } catch (_) {}
      this.fd = undefined;
      const path = this.outputPath;
      this.outputPath = undefined;
      if (path) {
        try { fs.unlinkSync(path); } catch (_) {}
      }
      replayError('ArkTsVideoEncoder', 'setupRecorderPipeline error: ' + String(e));
      throw e as Error;
      }
    } catch (err) {
      this.setupPromise = undefined;
      this.recorder = undefined;
      this.inputSurface = undefined;
      if (err instanceof Error) {
        throw err;
      }
      throw new Error(String(err));
    }
  }

  public async appendFrame(pm: image.PixelMap, timestampMs: number): Promise<void> {
    try {
      if (this.setupPromise) { await this.setupPromise; }
      if (!this.recorder || !this.inputSurface) {
        if (this.latestWindow) { this.delegate.setWindow(this.latestWindow); }
        await this.delegate.appendFrame(pm, timestampMs);
        return;
      }
      const frame = await this.inputSurface.requestFrame(this.width, this.height);
      const canvas: drawing.Canvas = frame.getCanvas();
      canvas.drawImage(pm, 0, 0);
      await this.inputSurface.flushFrame(frame);
    } catch (e) {
      replayWarn('ArkTsVideoEncoder', 'appendFrame via surface failed, fallback. err=' + String(e));
      this.setupPromise = undefined;
      this.recorder = undefined;
      this.inputSurface = undefined;
      await this.delegate.appendFrame(pm, timestampMs);
    }
  }

  public async captureSnapshot(): Promise<image.PixelMap | undefined> {
    return await this.delegate.captureSnapshot();
  }

  public isSnapshotInFlight(): boolean {
    return this.delegate.isSnapshotInFlight();
  }

  public async appendRawFrame(
    buffer: ArrayBuffer,
    width: number,
    height: number,
    stride: number,
    timestampMs: number,
    encoderWidth?: number,
    encoderHeight?: number,
  ): Promise<void> {
    replayDebug('ArkTsVideoEncoder', 'appendRawFrame entry: width=' + String(width) + ' height=' + String(height)
      + ' stride=' + String(stride) + ' encoderWidth=' + String(encoderWidth) + ' encoderHeight=' + String(encoderHeight)
      + ' bufferBytes=' + String(buffer.byteLength) + ' tsMs=' + String(timestampMs));
    try {
      if (this.setupPromise) { await this.setupPromise.catch(() => {}); }
    } catch (_) {}

    // 如果 AVRecorder Surface 模式可用，尝试将 ArrayBuffer 转换为 PixelMap 并使用 Surface
    if (this.recorder && this.inputSurface) {
      try {
        // 将 ArrayBuffer 转换为 PixelMap
        const pixelMap = await this.arrayBufferToPixelMap(buffer, width, height, stride);
        if (pixelMap) {
          const frame = await this.inputSurface.requestFrame(this.width, this.height);
          const canvas: drawing.Canvas = frame.getCanvas();
          canvas.drawImage(pixelMap, 0, 0);
          await this.inputSurface.flushFrame(frame);
          return;
        }
      } catch (err) {
        replayDebug('ArkTsVideoEncoder', 'appendRawFrame via PixelMap failed, trying direct appendRawFrame: ' + String(err));
      }
    }

    // 回退到 ShapeVideoEncoder：优先尝试直接传递 raw buffer，避免无效的 PixelMap 转换和潜在的 window.snapshot 劫持
    try {
      await this.delegate.appendRawFrame(buffer, width, height, stride, timestampMs, encoderWidth, encoderHeight);
      replayDebug('ArkTsVideoEncoder', 'appendRawFrame delegated to ShapeVideoEncoder successfully');
      return;
    } catch (err) {
      replayWarn('ArkTsVideoEncoder', 'appendRawFrame direct delegation failed: ' + String(err));
    }

    // 仅当直接传递失败时，才尝试 PixelMap 路径（作为最后兜底，可能触发 ShapeVideoEncoder 的 JPEG 序列逻辑）
    try {
      const pixelMap = await this.arrayBufferToPixelMap(buffer, width, height, stride);
      if (pixelMap) {
        await this.delegate.appendFrame(pixelMap, timestampMs);
        return;
      }
    } catch (err) {
      replayDebug('ArkTsVideoEncoder', 'appendRawFrame fallback via PixelMap also failed: ' + String(err));
    }
  }

  // 将 ArrayBuffer (RGBA) 转换为 PixelMap
  // 基于 HarmonyOS Image API：使用 createPixelMap 从 ArrayBuffer 创建
  private async arrayBufferToPixelMap(
    buffer: ArrayBuffer,
    width: number,
    height: number,
    stride: number
  ): Promise<image.PixelMap | undefined> {
    try {
      // 计算实际的行字节数（stride 可能大于 width * 4）
      const rowBytes = stride > 0 ? stride : (width * 4);
      const expectedSize = rowBytes * height;

      // 如果 buffer 大小不匹配，需要调整
      let workingBuffer = buffer;
      if (buffer.byteLength < expectedSize) {
        // Buffer 太小，无法创建完整的 PixelMap
        replayDebug('ArkTsVideoEncoder', 'arrayBufferToPixelMap: buffer too small: ' + buffer.byteLength + ' < ' + expectedSize);
        return undefined;
      } else if (buffer.byteLength > expectedSize) {
        // Buffer 太大，只使用需要的部分
        workingBuffer = buffer.slice(0, expectedSize);
      }

      // 使用 createPixelMap 从 ArrayBuffer 创建 PixelMap
      // 参考 ShapeFrameRenderer.ets 的实现
      const opts: image.InitializationOptions = {
        size: { width: width, height: height },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        alphaType: 1, // UNPREMUL
        editable: false
      } as image.InitializationOptions;

      const pixelMap = await image.createPixelMap(workingBuffer, opts);
      return pixelMap;
    } catch (err) {
      replayDebug('ArkTsVideoEncoder', 'arrayBufferToPixelMap failed: ' + String(err));
      return undefined;
    }
  }

  public getInputWindow(): bigint | undefined {
    return this.delegate.getInputWindow();
  }

  public setWindow(win: window.Window | undefined): void {
    this.latestWindow = win;
    this.delegate.setWindow(win);
  }

  public isInitialized(): boolean {
    return this.recorder !== undefined || this.delegate.isInitialized();
  }

  public getInitializedWidth(): number {
    // 优先返回 delegate 的实际初始化尺寸，因为 ShapeVideoEncoder 使用原生编码器的实际尺寸
    const delegateWidth = this.delegate.getInitializedWidth();
    return delegateWidth > 0 ? delegateWidth : this.width;
  }

  public getInitializedHeight(): number {
    // 优先返回 delegate 的实际初始化尺寸，因为 ShapeVideoEncoder 使用原生编码器的实际尺寸
    const delegateHeight = this.delegate.getInitializedHeight();
    return delegateHeight > 0 ? delegateHeight : this.height;
  }

  public async finalize(context: common.BaseContext): Promise<string | undefined> {
    try {
      if (this.setupPromise) { await this.setupPromise.catch(() => {}); }
      const rec = this.recorder;
      if (rec) {
        try { await rec.stop(); } catch (_) {}
        try { await rec.release(); } catch (_) {}
        this.recorder = undefined;
      }
      if (this.fd) {
        try { fs.close((this.fd as fs.File).fd); } catch (_) {}
        this.fd = undefined;
      }
      if (this.outputPath) {
        try {
          interface FsStat { size: number }
          const st = fs.statSync(this.outputPath) as FsStat;
          replayInfo('ArkTsVideoEncoder', 'finalize complete. path=' + this.outputPath + ', size=' + String(st.size));
        } catch (_) {}
        return this.outputPath;
      }
    } catch (_) {}
    return await this.delegate.finalize(context);
  }

  public getOutputPath(): string | undefined { return this.outputPath ?? this.delegate.getOutputPath(); }
  public getOutputSize(): number | undefined {
    try {
      const p = this.getOutputPath();
      if (!p) { return this.delegate.getOutputSize(); }
      interface FsStat { size: number }
      const st = fs.statSync(p) as FsStat;
      return st.size;
    } catch (_) {
      return this.delegate.getOutputSize();
    }
  }

  private resolveBaseDir(ctx: common.BaseContext): string | undefined {
    interface FileDirProvider { filesDir?: string; cacheDir?: string }
    const p = ctx as FileDirProvider;
    return p.filesDir ?? p.cacheDir;
  }
}


