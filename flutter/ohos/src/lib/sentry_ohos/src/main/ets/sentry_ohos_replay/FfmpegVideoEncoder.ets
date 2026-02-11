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

import fs from '@ohos.file.fs';
import fileio from '@ohos.fileio';
import common from '@ohos.app.ability.common';
import util from '@ohos.util';
import media from '@ohos.multimedia.media';
import image from '@ohos.multimedia.image';
import { replayInfo, replayWarn, replayError, replayDebug } from './ReplayLogger';

// 定义 Process 模块接口
interface ProcessModule {
  exec(command: string, callback: (error: Error | null, stdout: string, stderr: string) => void): void;
}

interface GlobalWithProcess {
  process?: ProcessModule;
  requireNapi?: (module: string) => FfmpegNativeModule | undefined;
}

// 定义 Native FFmpeg 模块接口
interface FfmpegNativeModule {
  mergeFrames(framesDir: string, outputPath: string, width: number, height: number, fps: number): Promise<boolean>;
}

/**
 * FFmpeg 视频编码器
 * 用于将 JPEG 序列合并成 MP4 视频文件
 *
 * 注意：HarmonyOS 可能没有内置 ffmpeg，此实现尝试调用系统命令
 * 如果系统不支持，将返回错误，由上层处理
 */
export class FfmpegVideoEncoder {
  private framesDir?: string;
  private outputPath?: string;
  private width: number = 720;
  private height: number = 1280;
  private fps: number = 2;
  private context?: common.BaseContext;

  /**
   * 初始化编码器
   */
  public init(context: common.BaseContext, framesDir: string, width: number = 720, height: number = 1280, fps: number = 2): void {
    this.context = context;
    this.framesDir = framesDir;
    this.width = width;
    this.height = height;
    this.fps = fps;
    replayInfo('FfmpegVideoEncoder', 'init: framesDir=' + framesDir + ', size=' + width + 'x' + height + '@' + fps);
  }

  /**
   * 将 JPEG 序列合并成 MP4 视频
   * @returns 生成的视频文件路径，如果失败返回 undefined
   */
  public async mergeFramesToVideo(): Promise<string | undefined> {
    if (!this.framesDir || !this.context) {
      replayWarn('FfmpegVideoEncoder', 'mergeFramesToVideo: framesDir or context is undefined');
      return undefined;
    }

    try {
      // 检查 framesDir 是否存在
      try {
        if (!fs.accessSync(this.framesDir)) {
          replayWarn('FfmpegVideoEncoder', 'mergeFramesToVideo: framesDir does not exist: ' + this.framesDir);
          return undefined;
        }
      } catch (accessErr) {
        replayWarn('FfmpegVideoEncoder', 'mergeFramesToVideo: cannot access framesDir: ' + String(accessErr));
        return undefined;
      }

      // 获取所有 JPEG 文件
      let files: string[] = [];
      try {
        files = fs.listFileSync(this.framesDir);
      } catch (listErr) {
        replayWarn('FfmpegVideoEncoder', 'mergeFramesToVideo: cannot list files in framesDir: ' + String(listErr));
        return undefined;
      }
      const jpegFiles = files.filter((f: string) => {
        return f.endsWith('.jpg') || f.endsWith('.jpeg') || f.endsWith('.png');
      }).sort(); // 按文件名排序

      if (jpegFiles.length === 0) {
        replayWarn('FfmpegVideoEncoder', 'mergeFramesToVideo: no JPEG files found in ' + this.framesDir);
        return undefined;
      }

      replayInfo('FfmpegVideoEncoder', 'mergeFramesToVideo: found ' + jpegFiles.length + ' frame files');

      // 使用首帧检测真实分辨率，以避免容器尺寸与帧数据不一致
      await this.updateDimensionsFromSample(jpegFiles[0]);

      // 生成输出视频文件路径
      const base = this.resolveBaseDir(this.context);
      if (!base) {
        replayWarn('FfmpegVideoEncoder', 'mergeFramesToVideo: cannot resolve base directory');
        return undefined;
      }

      const ts = Date.now();
      // 优先尝试生成 MP4，失败则回退到 AVI
      const outputPath = `${base}/replay_${ts}.mp4`;
      this.outputPath = outputPath;

      // 优先尝试使用 ffmpeg 命令合并视频
      // 如果 ffmpeg 不可用，回退到纯 ArkTS MJPEG 编码
      const ffmpegSuccess = await this.executeFfmpegCommand(jpegFiles, outputPath);

      if (ffmpegSuccess) {
        // 验证输出文件是否存在且有效
        try {
          const stat = fs.statSync(outputPath);
          const size = stat && typeof stat.size === 'number' ? (stat.size as number) : -1;
          if (size > 1024) { // 至少 1KB
            replayInfo('FfmpegVideoEncoder', 'mergeFramesToVideo: ffmpeg success, output=' + outputPath + ', size=' + size);
            return outputPath;
          } else {
            replayWarn('FfmpegVideoEncoder', 'mergeFramesToVideo: ffmpeg output file too small: ' + size);
            try { fs.unlinkSync(outputPath); } catch (_) {}
          }
        } catch (statErr) {
          replayWarn('FfmpegVideoEncoder', 'mergeFramesToVideo: failed to stat ffmpeg output file: ' + String(statErr));
        }
      }

      // ffmpeg 不可用，尝试使用 HarmonyOS MediaCodec + MediaMuxer 创建 MP4
      replayInfo('FfmpegVideoEncoder', 'mergeFramesToVideo: ffmpeg unavailable, trying HarmonyOS MediaCodec for MP4');
      const mp4Path = await this.createMP4Video(jpegFiles, outputPath);
      if (mp4Path) {
        try {
          const stat = fs.statSync(mp4Path);
          const size = stat && typeof stat.size === 'number' ? (stat.size as number) : -1;
          if (size > 1024) {
            replayInfo('FfmpegVideoEncoder', 'mergeFramesToVideo: MP4 success, output=' + mp4Path + ', size=' + size);
            this.outputPath = mp4Path;
            return mp4Path;
          }
        } catch (statErr) {
          replayWarn('FfmpegVideoEncoder', 'mergeFramesToVideo: failed to stat MP4 output file: ' + String(statErr));
        }
      }

      // 如果 MediaCodec 也失败，回退到 AVI MJPEG
      replayInfo('FfmpegVideoEncoder', 'mergeFramesToVideo: MediaCodec failed, falling back to AVI MJPEG');
      const mjpegPath = await this.createMJPEGVideo(jpegFiles, outputPath);
      if (mjpegPath) {
        try {
          const stat = fs.statSync(mjpegPath);
          const size = stat && typeof stat.size === 'number' ? (stat.size as number) : -1;
          if (size > 1024) {
            replayInfo('FfmpegVideoEncoder', 'mergeFramesToVideo: MJPEG success, output=' + mjpegPath + ', size=' + size);
            this.outputPath = mjpegPath;
            return mjpegPath;
          }
        } catch (statErr) {
          replayWarn('FfmpegVideoEncoder', 'mergeFramesToVideo: failed to stat MJPEG output file: ' + String(statErr));
        }
      }

      replayWarn('FfmpegVideoEncoder', 'mergeFramesToVideo: all encoding methods failed');
      return undefined;
    } catch (err) {
      replayError('FfmpegVideoEncoder', 'mergeFramesToVideo error: ' + String(err));
      return undefined;
    }
  }

  /**
   * 执行 ffmpeg 命令
   * 注意：HarmonyOS 可能不支持直接执行系统命令
   * 这里提供一个接口，实际实现可能需要通过 Native API 调用
   */
  private async executeFfmpegCommand(jpegFiles: string[], outputPath: string): Promise<boolean> {
    try {
      // 方案1：尝试通过 process 模块执行命令（如果 HarmonyOS 支持）
      // 注意：HarmonyOS 可能不支持 process 模块，需要检查
      const processModule = this.tryGetProcessModule();
      if (processModule) {
        return await this.executeViaProcess(processModule, jpegFiles, outputPath);
      }

      // 方案2：尝试通过 Native API 调用 ffmpeg
      // 这需要 Native 层实现 ffmpeg 调用
      const nativeFfmpeg = this.tryGetNativeFfmpeg();
      if (nativeFfmpeg) {
        return await this.executeViaNative(nativeFfmpeg, jpegFiles, outputPath);
      }
      // ffmpeg 不可用
      replayWarn('FfmpegVideoEncoder', 'executeFfmpegCommand: ffmpeg not available');
      return false;
    } catch (err) {
      replayError('FfmpegVideoEncoder', 'executeFfmpegCommand error: ' + String(err));
      return false;
    }
  }

  /**
   * 尝试获取 process 模块（如果 HarmonyOS 支持）
   */
  private tryGetProcessModule(): ProcessModule | undefined {
    try {
      // HarmonyOS 可能不支持 process 模块，这里只是尝试
      const globalObj: GlobalWithProcess = globalThis as GlobalWithProcess;
      if (globalObj.process && typeof globalObj.process.exec === 'function') {
        return globalObj.process;
      }
    } catch (_) {}
    return undefined;
  }

  /**
   * 尝试获取 Native FFmpeg API（如果可用）
   */
  private tryGetNativeFfmpeg(): FfmpegNativeModule | undefined {
    try {
      const globalObj: GlobalWithProcess = globalThis as GlobalWithProcess;
      const requireNapi = globalObj.requireNapi;
      if (typeof requireNapi === 'function') {
        const ffmpegModule = requireNapi('ffmpeg');
        if (ffmpegModule && typeof ffmpegModule.mergeFrames === 'function') {
          return ffmpegModule as FfmpegNativeModule;
        }
      }
    } catch (_) {}
    return undefined;
  }

  /**
   * 通过 process 模块执行 ffmpeg 命令
   */
  private async executeViaProcess(process: ProcessModule, jpegFiles: string[], outputPath: string): Promise<boolean> {
    try {
      // 构建 ffmpeg 命令
      // ffmpeg -framerate 2 -i frame_%d.jpg -c:v libx264 -pix_fmt yuv420p output.mp4
      const framePattern = this.framesDir + '/frame_%d.jpg';
      const command = `ffmpeg -y -framerate ${this.fps} -i "${framePattern}" -c:v libx264 -pix_fmt yuv420p -s ${this.width}x${this.height} "${outputPath}"`;

      return new Promise<boolean>((resolve) => {
        process.exec(command, (error: Error | null, stdout: string, stderr: string) => {
          if (error) {
            replayError('FfmpegVideoEncoder', 'executeViaProcess error: ' + String(error));
            resolve(false);
          } else {
            replayInfo('FfmpegVideoEncoder', 'executeViaProcess success');
            resolve(true);
          }
        });
      });
    } catch (err) {
      replayError('FfmpegVideoEncoder', 'executeViaProcess error: ' + String(err));
      return false;
    }
  }

  /**
   * 通过 Native API 执行 ffmpeg
   */
  private async executeViaNative(nativeFfmpeg: FfmpegNativeModule, jpegFiles: string[], outputPath: string): Promise<boolean> {
    try {
      if (!this.framesDir) {
        return false;
      }
      const result = await nativeFfmpeg.mergeFrames(
        this.framesDir,
        outputPath,
        this.width,
        this.height,
        this.fps
      );
      return result === true;
    } catch (err) {
      replayError('FfmpegVideoEncoder', 'executeViaNative error: ' + String(err));
      return false;
    }
  }


  /**
   * 使用 HarmonyOS MediaCodec + MediaMuxer 创建 MP4 视频
   * 将 JPEG 图像序列编码为 H.264 MP4 格式
   */
  /**
   * 创建简化的 MP4 容器（fMP4 格式）
   * 将 JPEG 图像序列封装为 MP4 MJPEG 轨道
   * 这是一个简化的实现，生成可播放的 MP4 文件
   */
  private async createMP4Video(jpegFiles: string[], outputPath: string): Promise<string | undefined> {
    try {
      if (!this.framesDir || !this.context) {
        return undefined;
      }

      replayInfo('FfmpegVideoEncoder', 'createMP4Video: starting MP4 container creation with ' + jpegFiles.length + ' frames');

      // 先读取所有 JPEG 帧到内存
      const frameData: Array<Uint8Array> = [];
      const frameSizes: number[] = [];
      let totalFramesSize = 0;

      for (let i = 0; i < jpegFiles.length; i++) {
        const jpegFile = jpegFiles[i];
        const fullPath = `${this.framesDir}/${jpegFile}`;

        try {
          const jpegFileHandle = fs.openSync(fullPath, fs.OpenMode.READ_ONLY);
          try {
            const jpegStat = fs.statSync(jpegFileHandle.fd);
            const jpegSize = jpegStat && typeof jpegStat.size === 'number' ? (jpegStat.size as number) : 0;

            if (jpegSize > 0) {
              const jpegBuffer = new ArrayBuffer(jpegSize);
              const bytesRead = fs.readSync(jpegFileHandle.fd, jpegBuffer);

              if (bytesRead > 0) {
                frameData.push(new Uint8Array(jpegBuffer, 0, bytesRead));
                frameSizes.push(bytesRead);
                totalFramesSize += bytesRead;
              }
            }
          } finally {
            fs.closeSync(jpegFileHandle);
          }
        } catch (readErr) {
          replayWarn('FfmpegVideoEncoder', 'createMP4Video: failed to read frame ' + jpegFile + ': ' + String(readErr));
        }
      }

      if (frameData.length === 0) {
        replayWarn('FfmpegVideoEncoder', 'createMP4Video: no valid frames to encode');
        return undefined;
      }

      // 创建简化的 MP4 容器（fMP4 格式）
      // MP4 格式基于 ISO Base Media File Format，包含以下主要 box：
      // - ftyp: 文件类型
      // - moov: 元数据（包含 mvhd, trak 等）
      // - mdat: 媒体数据

      const mp4Chunks: Uint8Array[] = [];
      const timescale = 1000; // 时间刻度（毫秒）
      const duration = Math.floor((frameData.length * 1000) / this.fps); // 总时长（毫秒）
      const frameDuration = Math.floor(1000 / this.fps); // 每帧时长（毫秒）

      // 2. moov box (元数据)
      const moovChunks: Uint8Array[] = [];

      // 2.1 mvhd box (Movie Header)
      moovChunks.push(this.createMvhdBox(timescale, duration));

      // 2.2 trak box (Track)
      const trakChunks: Uint8Array[] = [];

      // 2.2.1 tkhd box (Track Header)
      trakChunks.push(this.createTkhdBox(timescale, duration, this.width, this.height));

      // 2.2.2 mdia box (Media)
      const mdiaChunks: Uint8Array[] = [];

      // 2.2.2.1 mdhd box (Media Header)
      mdiaChunks.push(this.createMdhdBox(timescale, duration));

      // 2.2.2.2 hdlr box (Handler)
      mdiaChunks.push(this.createHdlrBox('vide', 'VideoHandler'));

      // 2.2.2.3 minf box (Media Information)
      const minfChunks: Uint8Array[] = [];

      // 2.2.2.3.1 vmhd box (Video Media Header)
      minfChunks.push(this.createVmhdBox());

      // 2.2.2.3.2 dinf box (Data Information)
      minfChunks.push(this.createDinfBox());

      // 2.2.2.3.3 stbl box (Sample Table)
      const stblChunks: Uint8Array[] = [];

      // 计算 sample 信息
      const sampleSizes: number[] = frameSizes;
      const sampleOffsets: number[] = [];
      let currentOffset = 0;
      for (let i = 0; i < frameSizes.length; i++) {
        sampleOffsets.push(currentOffset);
        currentOffset += frameSizes[i];
      }

      // 2.2.2.3.3.1 stsd box (Sample Description)
      stblChunks.push(this.createStsdBox(this.width, this.height));

      // 2.2.2.3.3.2 stts box (Time-to-Sample)
      stblChunks.push(this.createSttsBox(frameData.length, frameDuration));

      // 2.2.2.3.3.3 stsc box (Sample-to-Chunk)
      stblChunks.push(this.createStscBox(sampleOffsets.length, 1));

      // 2.2.2.3.3.4 stsz box (Sample Size)
      stblChunks.push(this.createStszBox(sampleSizes));

      // 2.2.2.3.3.5 stco box (Chunk Offset) - 先使用临时偏移量，稍后更新
      const stcoBoxTemp = this.createStcoBox(sampleOffsets, 0);
      stblChunks.push(stcoBoxTemp);

      // 临时组装所有 box 以计算 moov 大小
      const tempStblBox = this.createBox('stbl', stblChunks);
      minfChunks.push(tempStblBox);
      const tempMinfBox = this.createBox('minf', minfChunks);
      mdiaChunks.push(tempMinfBox);
      const tempMdiaBox = this.createBox('mdia', mdiaChunks);
      trakChunks.push(tempMdiaBox);
      const tempTrakBox = this.createBox('trak', trakChunks);
      moovChunks.push(tempTrakBox);
      const tempMoovBox = this.createBox('moov', moovChunks);

      // 计算 mdat 偏移量（ftyp + moov 的大小）
      const ftypBox = this.createFtypBox();
      const ftypSize = ftypBox.length;
      const moovSize = tempMoovBox.length;
      const mdatOffset = ftypSize + moovSize;

      // 使用正确的偏移量重新创建 stco box
      const finalStcoBox = this.createStcoBox(sampleOffsets, mdatOffset);

      // 重新构建所有 box（使用正确的 stco）
      const finalStblChunks: Uint8Array[] = [];
      finalStblChunks.push(this.createStsdBox(this.width, this.height));
      finalStblChunks.push(this.createSttsBox(frameData.length, frameDuration));
      finalStblChunks.push(this.createStscBox(sampleOffsets.length, 1));
      finalStblChunks.push(this.createStszBox(sampleSizes));
      finalStblChunks.push(finalStcoBox);
      const finalStblBox = this.createBox('stbl', finalStblChunks);

      const finalMinfChunks: Uint8Array[] = [];
      finalMinfChunks.push(this.createVmhdBox());
      finalMinfChunks.push(this.createDinfBox());
      finalMinfChunks.push(finalStblBox);
      const finalMinfBox = this.createBox('minf', finalMinfChunks);

      const finalMdiaChunks: Uint8Array[] = [];
      finalMdiaChunks.push(this.createMdhdBox(timescale, duration));
      finalMdiaChunks.push(this.createHdlrBox('vide', 'VideoHandler'));
      finalMdiaChunks.push(finalMinfBox);
      const finalMdiaBox = this.createBox('mdia', finalMdiaChunks);

      const finalTrakChunks: Uint8Array[] = [];
      finalTrakChunks.push(this.createTkhdBox(timescale, duration, this.width, this.height));
      finalTrakChunks.push(finalMdiaBox);
      const finalTrakBox = this.createBox('trak', finalTrakChunks);

      const finalMoovChunks: Uint8Array[] = [];
      finalMoovChunks.push(this.createMvhdBox(timescale, duration));
      finalMoovChunks.push(finalTrakBox);
      const finalMoovBox = this.createBox('moov', finalMoovChunks);

      // 3. mdat box (媒体数据)
      const mdatChunks: Uint8Array[] = [];
      for (let i = 0; i < frameData.length; i++) {
        mdatChunks.push(frameData[i]);
      }
      const mdatBox = this.createBox('mdat', mdatChunks);

      // 合并所有块
      mp4Chunks.push(ftypBox);
      mp4Chunks.push(finalMoovBox);
      mp4Chunks.push(mdatBox);

      // 合并所有块并写入文件
      const totalSize = this.calculateChunksSize(mp4Chunks);
      const finalBuffer = new Uint8Array(totalSize);
      let offset = 0;
      for (let i = 0; i < mp4Chunks.length; i++) {
        finalBuffer.set(mp4Chunks[i], offset);
        offset += mp4Chunks[i].length;
      }

      // 写入文件
      const outputFile = fs.openSync(outputPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(outputFile.fd, finalBuffer.buffer);
        replayInfo('FfmpegVideoEncoder', 'createMP4Video: created MP4 file with ' + frameData.length + ' frames, total size=' + totalSize);
        return outputPath;
      } finally {
        fs.closeSync(outputFile);
      }
    } catch (err) {
      replayError('FfmpegVideoEncoder', 'createMP4Video error: ' + String(err));
      return undefined;
    }
  }

  // MP4 Box 创建辅助方法
  private createBox(type: string, chunks: Array<Uint8Array>): Uint8Array {
    const size = 8 + this.calculateChunksSize(chunks); // 8 = size(4) + type(4)
    const result: Uint8Array[] = [];
    result.push(this.uint32ToBytesBE(size));
    result.push(this.stringToBytes(type));
    result.push(...chunks);
    return this.concatArrays(result);
  }

  private createFtypBox(): Uint8Array {
    // ftyp box: 文件类型声明
    // 对于 MJPEG 编码，使用更兼容的品牌声明以提高桌面播放器兼容性
    // 注意：MJPEG-in-MP4 的桌面播放器支持有限，这是编码格式本身的限制
    const majorBrand = 'isom'; // ISO Base Media
    const minorVersion = 0;
    // 使用更广泛的兼容性brands，包括Windows和Mac播放器支持的brands
    // isom: ISO Base Media file format (最广泛支持)
    // iso2: ISO Base Media file format v2
    // mp41: MP4 version 1 (广泛支持)
    // iso6: ISO Base Media file format v6 (改进的兼容性)
    // qt  : QuickTime (Mac和部分Windows播放器支持)
    const compatibleBrands = ['isom', 'iso2', 'mp41', 'iso6', 'qt  '];

    const chunks: Uint8Array[] = [];
    chunks.push(this.stringToBytes(majorBrand));
    chunks.push(this.uint32ToBytesBE(minorVersion));
    for (let i = 0; i < compatibleBrands.length; i++) {
      chunks.push(this.stringToBytes(compatibleBrands[i]));
    }

    return this.createBox('ftyp', chunks);
  }

  private createMvhdBox(timescale: number, duration: number): Uint8Array {
    // mvhd box: Movie Header (版本 0，32位时间)
    const version = 0;
    const flags = 0;
    const creationTime = 0;
    const modificationTime = 0;
    const rate = 0x00010000; // 1.0 (16.16 fixed point)
    const volume = 0x0100; // 1.0 (8.8 fixed point)
    const matrix = new Uint8Array(36); // 单位矩阵
    matrix[0] = 0x00; matrix[1] = 0x01; // 1.0
    matrix[4] = 0x00; matrix[5] = 0x01; // 1.0
    matrix[8] = 0x40; matrix[9] = 0x00; // 1.0 (16.16)
    matrix[10] = 0x00; matrix[11] = 0x00;
    matrix[12] = 0x00; matrix[13] = 0x00;
    matrix[14] = 0x00; matrix[15] = 0x00;
    matrix[16] = 0x00; matrix[17] = 0x01; // 1.0
    matrix[20] = 0x00; matrix[21] = 0x01; // 1.0
    matrix[24] = 0x40; matrix[25] = 0x00; // 1.0 (16.16)
    matrix[26] = 0x00; matrix[27] = 0x00;
    matrix[28] = 0x00; matrix[29] = 0x00;
    matrix[30] = 0x00; matrix[31] = 0x00;
    matrix[32] = 0x00; matrix[33] = 0x00;
    matrix[34] = 0x00; matrix[35] = 0x00;
    const nextTrackId = 2;

    const chunks: Uint8Array[] = [];
    chunks.push(new Uint8Array([version]));
    chunks.push(this.uint24ToBytesBE(flags));
    chunks.push(this.uint32ToBytesBE(creationTime));
    chunks.push(this.uint32ToBytesBE(modificationTime));
    chunks.push(this.uint32ToBytesBE(timescale));
    chunks.push(this.uint32ToBytesBE(duration));
    chunks.push(this.uint32ToBytesBE(rate));
    chunks.push(this.uint16ToBytesBE(volume));
    chunks.push(new Uint8Array(10)); // reserved
    chunks.push(matrix);
    chunks.push(this.uint32ToBytesBE(nextTrackId));

    return this.createBox('mvhd', chunks);
  }

  private createTkhdBox(timescale: number, duration: number, width: number, height: number): Uint8Array {
    // tkhd box: Track Header (版本 0)
    const version = 0;
    const flags = 0x000007; // track_enabled | track_in_movie | track_in_preview
    const creationTime = 0;
    const modificationTime = 0;
    const trackId = 1;
    const layer = 0;
    const alternateGroup = 0;
    const volume = 0; // 视频轨道
    const matrix = new Uint8Array(36); // 单位矩阵（同上）
    matrix[0] = 0x00; matrix[1] = 0x01;
    matrix[4] = 0x00; matrix[5] = 0x01;
    matrix[8] = 0x40; matrix[9] = 0x00;
    matrix[16] = 0x00; matrix[17] = 0x01;
    matrix[20] = 0x00; matrix[21] = 0x01;
    matrix[24] = 0x40; matrix[25] = 0x00;

    const chunks: Uint8Array[] = [];
    chunks.push(new Uint8Array([version]));
    chunks.push(this.uint24ToBytesBE(flags));
    chunks.push(this.uint32ToBytesBE(creationTime));
    chunks.push(this.uint32ToBytesBE(modificationTime));
    chunks.push(this.uint32ToBytesBE(trackId));
    chunks.push(new Uint8Array(4)); // reserved
    chunks.push(this.uint32ToBytesBE(duration));
    chunks.push(new Uint8Array(8)); // reserved
    chunks.push(this.int16ToBytesBE(layer));
    chunks.push(this.int16ToBytesBE(alternateGroup));
    chunks.push(this.int16ToBytesBE(volume));
    chunks.push(new Uint8Array(2)); // reserved
    chunks.push(matrix);
    chunks.push(this.uint32ToBytesBE(width << 16)); // width (16.16 fixed point)
    chunks.push(this.uint32ToBytesBE(height << 16)); // height (16.16 fixed point)

    return this.createBox('tkhd', chunks);
  }

  private createMdhdBox(timescale: number, duration: number): Uint8Array {
    // mdhd box: Media Header (版本 0)
    const version = 0;
    const flags = 0;
    const creationTime = 0;
    const modificationTime = 0;
    const language = 0x55C4; // 'und' (undetermined)
    const quality = 0;

    const chunks: Uint8Array[] = [];
    chunks.push(new Uint8Array([version]));
    chunks.push(this.uint24ToBytesBE(flags));
    chunks.push(this.uint32ToBytesBE(creationTime));
    chunks.push(this.uint32ToBytesBE(modificationTime));
    chunks.push(this.uint32ToBytesBE(timescale));
    chunks.push(this.uint32ToBytesBE(duration));
    chunks.push(this.uint16ToBytesBE(language));
    chunks.push(this.uint16ToBytesBE(quality));

    return this.createBox('mdhd', chunks);
  }

  private createHdlrBox(handlerType: string, name: string): Uint8Array {
    // hdlr box: Handler Reference
    const version = 0;
    const flags = 0;
    const preDefined = 0;
    const reserved = new Uint8Array(12);

    const chunks: Uint8Array[] = [];
    chunks.push(new Uint8Array([version]));
    chunks.push(this.uint24ToBytesBE(flags));
    chunks.push(this.uint32ToBytesBE(preDefined));
    chunks.push(this.stringToBytes(handlerType));
    chunks.push(reserved);
    const nameBytes = this.stringToBytes(name);
    chunks.push(nameBytes);

    return this.createBox('hdlr', chunks);
  }

  private createVmhdBox(): Uint8Array {
    // vmhd box: Video Media Header
    const version = 0;
    const flags = 1; // kVideoNoLeanAhead
    const graphicsMode = 0; // copy
    const opColor = new Uint8Array(6); // 0, 0, 0

    const chunks: Uint8Array[] = [];
    chunks.push(new Uint8Array([version]));
    chunks.push(this.uint24ToBytesBE(flags));
    chunks.push(this.uint16ToBytesBE(graphicsMode));
    chunks.push(opColor);

    return this.createBox('vmhd', chunks);
  }

  private createDinfBox(): Uint8Array {
    // dinf box: Data Information
    // 包含 dref box
    const drefChunks: Uint8Array[] = [];
    const version = 0;
    const flags = 0;
    const entryCount = 1;

    // url box (Data Reference URL)
    const urlChunks: Uint8Array[] = [];
    urlChunks.push(new Uint8Array([version]));
    urlChunks.push(this.uint24ToBytesBE(1)); // flags: self-contained
    const urlBox = this.createBox('url ', urlChunks);

    drefChunks.push(new Uint8Array([version]));
    drefChunks.push(this.uint24ToBytesBE(flags));
    drefChunks.push(this.uint32ToBytesBE(entryCount));
    drefChunks.push(urlBox);

    const drefBox = this.createBox('dref', drefChunks);
    return this.createBox('dinf', [drefBox]);
  }

  private createStsdBox(width: number, height: number): Uint8Array {
    // stsd box: Sample Description
    const version = 0;
    const flags = 0;
    const entryCount = 1;

    // mjpeg box (MJPEG Video Sample Entry) - strictly follow ISO/IEC 14496-12 VisualSampleEntry layout
    const mjpegChunks: Uint8Array[] = [];
    mjpegChunks.push(new Uint8Array(6)); // reserved
    mjpegChunks.push(this.uint16ToBytesBE(1)); // data_reference_index
    mjpegChunks.push(this.uint16ToBytesBE(0)); // pre_defined
    mjpegChunks.push(this.uint16ToBytesBE(0)); // reserved
    mjpegChunks.push(new Uint8Array(12)); // pre_defined[3]
    mjpegChunks.push(this.uint16ToBytesBE(width)); // width
    mjpegChunks.push(this.uint16ToBytesBE(height)); // height
    mjpegChunks.push(this.uint32ToBytesBE(0x00480000)); // horizontal_resolution (72 dpi, 16.16)
    mjpegChunks.push(this.uint32ToBytesBE(0x00480000)); // vertical_resolution (72 dpi, 16.16)
    mjpegChunks.push(this.uint32ToBytesBE(0)); // data_size
    mjpegChunks.push(this.uint16ToBytesBE(1)); // frame_count
    const nameBuffer = new Uint8Array(32);
    const compressor = 'MJPEG';
    nameBuffer[0] = Math.min(31, compressor.length);
    for (let i = 0; i < Math.min(31, compressor.length); i++) {
      nameBuffer[i + 1] = compressor.charCodeAt(i);
    }
    mjpegChunks.push(nameBuffer);
    mjpegChunks.push(this.uint16ToBytesBE(24)); // depth
    mjpegChunks.push(this.int16ToBytesBE(-1)); // color_table_id

    const mjpegBox = this.createBox('mjpg', mjpegChunks);

    const chunks: Uint8Array[] = [];
    chunks.push(new Uint8Array([version]));
    chunks.push(this.uint24ToBytesBE(flags));
    chunks.push(this.uint32ToBytesBE(entryCount));
    chunks.push(mjpegBox);

    return this.createBox('stsd', chunks);
  }

  private createSttsBox(sampleCount: number, sampleDelta: number): Uint8Array {
    // stts box: Time-to-Sample
    const version = 0;
    const flags = 0;
    const entryCount = 1;

    const chunks: Uint8Array[] = [];
    chunks.push(new Uint8Array([version]));
    chunks.push(this.uint24ToBytesBE(flags));
    chunks.push(this.uint32ToBytesBE(entryCount));
    chunks.push(this.uint32ToBytesBE(sampleCount)); // sample_count
    chunks.push(this.uint32ToBytesBE(sampleDelta)); // sample_delta

    return this.createBox('stts', chunks);
  }

  private createStscBox(chunkCount: number, samplesPerChunk: number = 1): Uint8Array {
    // stsc box: Sample-to-Chunk
    const version = 0;
    const flags = 0;
    const entryCount = 1;

    const chunks: Uint8Array[] = [];
    chunks.push(new Uint8Array([version]));
    chunks.push(this.uint24ToBytesBE(flags));
    chunks.push(this.uint32ToBytesBE(entryCount));
    chunks.push(this.uint32ToBytesBE(1)); // first_chunk index starts at 1
    chunks.push(this.uint32ToBytesBE(Math.max(1, samplesPerChunk))); // samples_per_chunk
    chunks.push(this.uint32ToBytesBE(1)); // sample_description_index

    return this.createBox('stsc', chunks);
  }

  private createStszBox(sampleSizes: number[]): Uint8Array {
    // stsz box: Sample Size
    const version = 0;
    const flags = 0;
    const sampleSize = 0; // variable size
    const sampleCount = sampleSizes.length;

    const chunks: Uint8Array[] = [];
    chunks.push(new Uint8Array([version]));
    chunks.push(this.uint24ToBytesBE(flags));
    chunks.push(this.uint32ToBytesBE(sampleSize));
    chunks.push(this.uint32ToBytesBE(sampleCount));
    for (let i = 0; i < sampleSizes.length; i++) {
      chunks.push(this.uint32ToBytesBE(sampleSizes[i]));
    }

    return this.createBox('stsz', chunks);
  }

  private createStcoBox(chunkOffsets: number[], mdatOffset: number): Uint8Array {
    // stco box: Chunk Offset (32-bit)
    // 注意：偏移量是相对于文件开始的位置，指向 mdat box 内的数据
    // 为了Windows播放器兼容性，确保offset计算准确
    const version = 0;
    const flags = 0;
    const entryCount = chunkOffsets.length;

    const chunks: Uint8Array[] = [];
    chunks.push(new Uint8Array([version]));
    chunks.push(this.uint24ToBytesBE(flags));
    chunks.push(this.uint32ToBytesBE(entryCount));
    for (let i = 0; i < chunkOffsets.length; i++) {
      // mdatOffset 是 mdat box 在文件中的位置（包括box header）
      // +8 是 mdat box 头部（size 4 bytes + type 4 bytes = 8 bytes）
      // chunkOffsets[i] 是数据在 mdat box 内的偏移（从mdat数据开始计算）
      // 最终offset = mdat box位置 + 8字节header + 数据在mdat内的偏移
      const absoluteOffset = mdatOffset + 8 + chunkOffsets[i];
      chunks.push(this.uint32ToBytesBE(absoluteOffset));
    }

    return this.createBox('stco', chunks);
  }

  // MP4 辅助方法（大端序）
  private uint32ToBytesBE(value: number): Uint8Array {
    const bytes = new Uint8Array(4);
    bytes[0] = (value >>> 24) & 0xFF;
    bytes[1] = (value >>> 16) & 0xFF;
    bytes[2] = (value >>> 8) & 0xFF;
    bytes[3] = value & 0xFF;
    return bytes;
  }

  private uint24ToBytesBE(value: number): Uint8Array {
    const bytes = new Uint8Array(3);
    bytes[0] = (value >>> 16) & 0xFF;
    bytes[1] = (value >>> 8) & 0xFF;
    bytes[2] = value & 0xFF;
    return bytes;
  }

  private uint16ToBytesBE(value: number): Uint8Array {
    const bytes = new Uint8Array(2);
    bytes[0] = (value >>> 8) & 0xFF;
    bytes[1] = value & 0xFF;
    return bytes;
  }

  private int16ToBytesBE(value: number): Uint8Array {
    const uint16 = value & 0xFFFF;
    return this.uint16ToBytesBE(uint16);
  }

  private concatArrays(arrays: Array<Uint8Array>): Uint8Array {
    const totalLength = this.calculateChunksSize(arrays);
    const result = new Uint8Array(totalLength);
    let offset = 0;
    for (let i = 0; i < arrays.length; i++) {
      result.set(arrays[i], offset);
      offset += arrays[i].length;
    }
    return result;
  }

  /**
   * 创建 MJPEG 视频文件（纯 ArkTS 实现，无需 ffmpeg）
   * 创建一个简单的 AVI MJPEG 容器格式
   * AVI 格式相对简单，可以在纯 ArkTS 中实现
   */
  private async createMJPEGVideo(jpegFiles: string[], outputPath: string): Promise<string | undefined> {
    try {
      if (!this.framesDir) {
        return undefined;
      }

      // 先读取所有 JPEG 帧到内存
      const frameData: Array<Uint8Array> = [];
      const frameSizes: number[] = [];
      let totalFramesSize = 0;

      for (let i = 0; i < jpegFiles.length; i++) {
        const jpegFile = jpegFiles[i];
        const fullPath = `${this.framesDir}/${jpegFile}`;

        try {
          const jpegFileHandle = fs.openSync(fullPath, fs.OpenMode.READ_ONLY);
          try {
            const jpegStat = fs.statSync(jpegFileHandle.fd);
            const jpegSize = jpegStat && typeof jpegStat.size === 'number' ? (jpegStat.size as number) : 0;

            if (jpegSize > 0) {
              const jpegBuffer = new ArrayBuffer(jpegSize);
              const bytesRead = fs.readSync(jpegFileHandle.fd, jpegBuffer);

              if (bytesRead > 0) {
                frameData.push(new Uint8Array(jpegBuffer, 0, bytesRead));
                frameSizes.push(bytesRead);
                totalFramesSize += bytesRead;
              }
            }
          } finally {
            fs.closeSync(jpegFileHandle);
          }
        } catch (readErr) {
          replayWarn('FfmpegVideoEncoder', 'createMJPEGVideo: failed to read frame ' + jpegFile + ': ' + String(readErr));
        }
      }

      if (frameData.length === 0) {
        replayWarn('FfmpegVideoEncoder', 'createMJPEGVideo: no valid frames to encode');
        return undefined;
      }

      // 创建 AVI 文件（先构建到内存，然后一次性写入，避免 seek）
      const aviChunks: Uint8Array[] = [];

      // 计算 movi 部分大小（包括所有帧和填充，用于估算总文件大小）
      let estimatedMoviSize = 4; // 'movi' 字符串
      for (let i = 0; i < frameData.length; i++) {
        const chunkSize = 4 + 4 + frameSizes[i] + (frameSizes[i] % 2); // '00dc' + size + data + padding
        estimatedMoviSize += chunkSize;
      }

      // 计算总文件大小（估算，用于 RIFF 头）
      const hdrlSize = 4 + 4 + 4 + 56 + 4 + 4 + 4 + 56 + 4 + 40; // LIST + hdrl + LIST + strl + strh + strf
      const idx1Size = 4 + 4 + (16 * frameData.length); // 'idx1' + size + index entries
      const estimatedTotalFileSize = 4 + 4 + 4 + hdrlSize + 4 + 4 + estimatedMoviSize + idx1Size; // RIFF + AVI + hdrl + movi + idx1

      // 构建 RIFF 头（使用估算大小，稍后会更新）
      aviChunks.push(this.stringToBytes('RIFF'));
      aviChunks.push(this.uint32ToBytesLE(estimatedTotalFileSize - 8)); // 文件大小 - 8（估算值）
      aviChunks.push(this.stringToBytes('AVI '));

      // 构建 hdrl LIST
      const hdrlChunks: Uint8Array[] = [];
      hdrlChunks.push(this.stringToBytes('LIST'));
      hdrlChunks.push(this.uint32ToBytesLE(0)); // 占位符
      hdrlChunks.push(this.stringToBytes('hdrl'));

      // 构建 avih (AVI Header)
      hdrlChunks.push(this.stringToBytes('avih'));
      hdrlChunks.push(this.uint32ToBytesLE(56));
      const microSecPerFrame = Math.floor(1000000 / this.fps);
      hdrlChunks.push(this.uint32ToBytesLE(microSecPerFrame));
      hdrlChunks.push(this.uint32ToBytesLE(0)); // maxBytesPerSec
      hdrlChunks.push(this.uint32ToBytesLE(0)); // paddingGranularity
      hdrlChunks.push(this.uint32ToBytesLE(0x10)); // flags
      hdrlChunks.push(this.uint32ToBytesLE(frameData.length)); // totalFrames
      hdrlChunks.push(this.uint32ToBytesLE(0)); // initialFrames
      hdrlChunks.push(this.uint32ToBytesLE(1)); // streams
      hdrlChunks.push(this.uint32ToBytesLE(0)); // suggestedBufferSize
      hdrlChunks.push(this.uint32ToBytesLE(this.width)); // width
      hdrlChunks.push(this.uint32ToBytesLE(this.height)); // height
      hdrlChunks.push(this.uint32ToBytesLE(0)); // reserved[0]
      hdrlChunks.push(this.uint32ToBytesLE(0)); // reserved[1]
      hdrlChunks.push(this.uint32ToBytesLE(0)); // reserved[2]
      hdrlChunks.push(this.uint32ToBytesLE(0)); // reserved[3]

      // 构建 strl LIST
      const strlChunks: Uint8Array[] = [];
      strlChunks.push(this.stringToBytes('LIST'));
      strlChunks.push(this.uint32ToBytesLE(0)); // 占位符
      strlChunks.push(this.stringToBytes('strl'));

      // 构建 strh (Stream Header)
      strlChunks.push(this.stringToBytes('strh'));
      strlChunks.push(this.uint32ToBytesLE(56));
      strlChunks.push(this.stringToBytes('vids'));
      strlChunks.push(this.stringToBytes('MJPG'));
      strlChunks.push(this.uint32ToBytesLE(0)); // flags
      strlChunks.push(this.uint16ToBytesLE(0)); // priority
      strlChunks.push(this.uint16ToBytesLE(0)); // language
      strlChunks.push(this.uint32ToBytesLE(0)); // initialFrames
      strlChunks.push(this.uint32ToBytesLE(1)); // scale
      strlChunks.push(this.uint32ToBytesLE(this.fps)); // rate
      strlChunks.push(this.uint32ToBytesLE(0)); // start
      strlChunks.push(this.uint32ToBytesLE(frameData.length)); // length
      strlChunks.push(this.uint32ToBytesLE(0)); // suggestedBufferSize
      strlChunks.push(this.uint32ToBytesLE(10000)); // quality
      strlChunks.push(this.uint32ToBytesLE(0)); // sampleSize
      strlChunks.push(this.int16ToBytesLE(0)); // left
      strlChunks.push(this.int16ToBytesLE(0)); // top
      strlChunks.push(this.int16ToBytesLE(this.width)); // right
      strlChunks.push(this.int16ToBytesLE(this.height)); // bottom

      // 构建 strf (Stream Format)
      strlChunks.push(this.stringToBytes('strf'));
      strlChunks.push(this.uint32ToBytesLE(40));
      strlChunks.push(this.uint32ToBytesLE(40)); // biSize
      strlChunks.push(this.int32ToBytesLE(this.width)); // biWidth
      strlChunks.push(this.int32ToBytesLE(this.height)); // biHeight
      strlChunks.push(this.uint16ToBytesLE(1)); // biPlanes
      strlChunks.push(this.uint16ToBytesLE(24)); // biBitCount
      strlChunks.push(this.stringToBytes('MJPG')); // biCompression
      strlChunks.push(this.uint32ToBytesLE(totalFramesSize)); // biSizeImage
      strlChunks.push(this.uint32ToBytesLE(0)); // biXPelsPerMeter
      strlChunks.push(this.uint32ToBytesLE(0)); // biYPelsPerMeter
      strlChunks.push(this.uint32ToBytesLE(0)); // biClrUsed
      strlChunks.push(this.uint32ToBytesLE(0)); // biClrImportant

      // 计算 strl LIST 大小并更新
      const strlSize = this.calculateChunksSize(strlChunks) - 8; // 减去 LIST 和大小字段
      strlChunks[1] = this.uint32ToBytesLE(strlSize);
      hdrlChunks.push(...strlChunks);

      // 计算 hdrl LIST 大小并更新
      const hdrlSizeActual = this.calculateChunksSize(hdrlChunks) - 8; // 减去 LIST 和大小字段
      hdrlChunks[1] = this.uint32ToBytesLE(hdrlSizeActual);
      aviChunks.push(...hdrlChunks);

      // 构建 movi LIST
      const moviChunks: Uint8Array[] = [];
      moviChunks.push(this.stringToBytes('LIST'));
      moviChunks.push(this.uint32ToBytesLE(0)); // 占位符
      moviChunks.push(this.stringToBytes('movi'));

      // 计算 movi 开始位置（用于索引）
      const moviStartOffset = this.calculateChunksSize(aviChunks) + 8; // +8 for LIST header

      // 添加所有帧数据
      const actualFrameOffsets: number[] = [];
      for (let i = 0; i < frameData.length; i++) {
        // 记录当前帧在 movi 中的偏移（相对于 movi 开始，不包括 'LIST' 和大小字段）
        const frameOffsetInMovi = this.calculateChunksSize(moviChunks) - 8; // -8 for LIST header
        actualFrameOffsets.push(frameOffsetInMovi);

        moviChunks.push(this.stringToBytes('00dc'));
        moviChunks.push(this.uint32ToBytesLE(frameSizes[i]));
        moviChunks.push(frameData[i]);
        // 如果帧大小是奇数，添加填充字节
        if (frameSizes[i] % 2 !== 0) {
          moviChunks.push(new Uint8Array([0]));
        }
      }

      // 更新 movi LIST 大小
      const moviSizeActual = this.calculateChunksSize(moviChunks) - 8;
      moviChunks[1] = this.uint32ToBytesLE(moviSizeActual);
      aviChunks.push(...moviChunks);

      // 构建 idx1 (Index)
      aviChunks.push(this.stringToBytes('idx1'));
      aviChunks.push(this.uint32ToBytesLE(16 * frameData.length));

      for (let i = 0; i < frameData.length; i++) {
        aviChunks.push(this.stringToBytes('00dc'));
        aviChunks.push(this.uint32ToBytesLE(0x10)); // flags (AVIIF_KEYFRAME)
        // offset 是相对于 movi 开始的位置（不包括 'LIST' 和大小字段，但包括 'movi' 字符串）
        aviChunks.push(this.uint32ToBytesLE(actualFrameOffsets[i] + 4)); // +4 for 'movi' string
        aviChunks.push(this.uint32ToBytesLE(frameSizes[i])); // size
      }

      // 合并所有块并写入文件
      const totalSize = this.calculateChunksSize(aviChunks);
      const finalBuffer = new Uint8Array(totalSize);
      let offset = 0;
      for (let i = 0; i < aviChunks.length; i++) {
        finalBuffer.set(aviChunks[i], offset);
        offset += aviChunks[i].length;
      }

      // 更新 RIFF 头中的文件大小（使用实际大小）
      const actualRiffSize = totalSize - 8; // 减去 RIFF 和大小字段本身
      const riffSizeBytes = this.uint32ToBytesLE(actualRiffSize);
      finalBuffer.set(riffSizeBytes, 4); // 位置 4 是 RIFF 大小字段

      // 写入文件
      const outputFile = fs.openSync(outputPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(outputFile.fd, finalBuffer.buffer);
        replayInfo('FfmpegVideoEncoder', 'createMJPEGVideo: created AVI MJPEG file with ' + frameData.length + ' frames, total size=' + totalSize);
        return outputPath;
      } finally {
        fs.closeSync(outputFile);
      }
    } catch (err) {
      replayError('FfmpegVideoEncoder', 'createMJPEGVideo error: ' + String(err));
      return undefined;
    }
  }

  // AVI 文件构建辅助方法（构建到内存，避免 seek）
  private stringToBytes(str: string): Uint8Array {
    const bytes = new Uint8Array(str.length);
    for (let i = 0; i < str.length; i++) {
      bytes[i] = str.charCodeAt(i);
    }
    return bytes;
  }

  private uint32ToBytesLE(value: number): Uint8Array {
    const bytes = new Uint8Array(4);
    bytes[0] = value & 0xFF;
    bytes[1] = (value >>> 8) & 0xFF;
    bytes[2] = (value >>> 16) & 0xFF;
    bytes[3] = (value >>> 24) & 0xFF;
    return bytes;
  }

  private uint16ToBytesLE(value: number): Uint8Array {
    const bytes = new Uint8Array(2);
    bytes[0] = value & 0xFF;
    bytes[1] = (value >>> 8) & 0xFF;
    return bytes;
  }

  private int32ToBytesLE(value: number): Uint8Array {
    // 将有符号整数转换为无符号整数
    const uint32 = value >>> 0;
    return this.uint32ToBytesLE(uint32);
  }

  private int16ToBytesLE(value: number): Uint8Array {
    // 将有符号整数转换为无符号整数
    const uint16 = value & 0xFFFF;
    return this.uint16ToBytesLE(uint16);
  }

  private calculateChunksSize(chunks: Array<Uint8Array>): number {
    let total = 0;
    for (let i = 0; i < chunks.length; i++) {
      total += chunks[i].length;
    }
    return total;
  }

  /**
   * 获取输出路径
   */
  public getOutputPath(): string | undefined {
    return this.outputPath;
  }

  /**
   * 获取输出文件大小
   */
  public getOutputSize(): number | undefined {
    try {
      if (!this.outputPath) {
        return undefined;
      }
      const st = fs.statSync(this.outputPath);
      return (st && typeof st.size === 'number') ? (st.size as number) : undefined;
    } catch (_) {
      return undefined;
    }
  }

  /**
   * 解析基础目录
   */
  private resolveBaseDir(ctx: common.BaseContext): string | undefined {
    interface FileDirProvider { filesDir?: string; cacheDir?: string }
    const p = ctx as FileDirProvider;
    return p.filesDir ?? p.cacheDir;
  }

  private async updateDimensionsFromSample(sampleFile: string): Promise<void> {
    if (!this.framesDir) {
      return;
    }
    const samplePath = `${this.framesDir}/${sampleFile}`;
    let fd: number | undefined;
    try {
      const O_RDONLY = 0o0;
      fd = fileio.openSync(samplePath, O_RDONLY);
      const imageSource = image.createImageSource(fd);
      const info = await imageSource.getImageInfo();
      const size = info?.size;
      const detectedWidth = size && typeof size.width === 'number' ? size.width : undefined;
      const detectedHeight = size && typeof size.height === 'number' ? size.height : undefined;
      if (detectedWidth && detectedWidth > 0 && detectedHeight && detectedHeight > 0) {
        if (detectedWidth !== this.width || detectedHeight !== this.height) {
          replayInfo('FfmpegVideoEncoder', 'updateDimensionsFromSample: detected frame size '
            + detectedWidth + 'x' + detectedHeight + ' (was ' + this.width + 'x' + this.height + ')');
        }
        this.width = detectedWidth;
        this.height = detectedHeight;
      }
    } catch (err) {
      replayDebug('FfmpegVideoEncoder', 'updateDimensionsFromSample failed: ' + String(err));
    } finally {
      if (fd !== undefined) {
        try { fileio.closeSync(fd); } catch (_) {}
      }
    }
  }
}

