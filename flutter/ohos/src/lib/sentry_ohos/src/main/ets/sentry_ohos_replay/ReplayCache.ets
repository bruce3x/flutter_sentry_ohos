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
import common from '@ohos.app.ability.common';
import { ReplayPayload } from './types';

interface FileDirProvider {
  filesDir?: string;
  cacheDir?: string;
}

const REPLAY_CACHE_TAG = '[Sentry] [ReplayCache]';
const CACHED_VIDEO_FILENAME = 'cached_replay_video.mp4';

/**
 * ReplayCache
 * - 保存 ReplayPayload 到本地文件
 * - 读取本地 ReplayPayload
 * - 清理缓存文件
 */
export class ReplayCache {
  private filename: string;
  private context?: common.BaseContext;
  private cacheFile?: string;
  private ongoingFile?: string;
  private cachedVideoFile?: string;
  private baseDir?: string;

  constructor(filename: string = "replay_cache.json") {
    this.filename = filename;
  }

  public setContext(ctx: common.BaseContext): void {
    this.context = ctx;
    const dirProvider: FileDirProvider = ctx as FileDirProvider;
    const baseDir: string | undefined = dirProvider.filesDir ?? dirProvider.cacheDir;
    if (!baseDir) {
      return;
    }
    this.baseDir = baseDir;
    this.cacheFile = `${baseDir}/${this.filename}`;
    this.ongoingFile = `${baseDir}/.ongoing_segment`;
    this.cachedVideoFile = `${baseDir}/${CACHED_VIDEO_FILENAME}`;
  }

  private stringToUint8Array(str: string): Uint8Array {
    const arr: number[] = [];
    for (let i = 0; i < str.length; i++) {
      arr.push(str.charCodeAt(i));
    }
    return new Uint8Array(arr);
  }

  private uint8ArrayToString(arr: Uint8Array): string {
    let str = '';
    for (let i = 0; i < arr.length; i++) {
      str += String.fromCharCode(arr[i]);
    }
    return str;
  }

  /** 追加保存（将历史与新 payload 合并写入） */
  public mergeAndSave(payload: ReplayPayload): void {
    try {
      const existing = this.load();
      const merged: ReplayPayload = existing && existing.sessionId === payload.sessionId
        ? { sessionId: payload.sessionId, events: [...existing.events, ...payload.events] }
        : payload;
      this.save(merged);
    } catch (_) {
      this.save(payload);
    }
  }

  /** 保存 ReplayPayload 到文件，同时复制视频文件到持久化位置 */
  public save(payload: ReplayPayload): void {
    try {
      if (!this.cacheFile || !this.baseDir) {
        console.warn(`${REPLAY_CACHE_TAG} Context not set, cannot persist replay`);
        return;
      }

      // 如果payload包含视频路径，复制视频到持久化位置
      if (payload.videoPath && payload.videoPath.length > 0 && this.cachedVideoFile) {
        try {
          // 检查源视频文件是否存在
          if (fs.accessSync(payload.videoPath)) {
            const srcStat = fs.statSync(payload.videoPath);
            const srcSize = srcStat && typeof srcStat.size === 'number' ? srcStat.size : 0;
            
            if (srcSize > 0) {
              // 复制视频文件到持久化位置
              // 先删除旧的缓存视频（如果存在）
              try {
                if (fs.accessSync(this.cachedVideoFile)) {
                  fs.unlinkSync(this.cachedVideoFile);
                }
              } catch (_) {}
              
              // 复制文件
              fs.copyFileSync(payload.videoPath, this.cachedVideoFile);
              
              // 更新payload中的视频路径为缓存位置
              payload.videoPath = this.cachedVideoFile;
              payload.videoSizeBytes = srcSize;
              
            }
          }
        } catch (_) {
        }
      }

      const content: string = JSON.stringify(payload);
      const buffer: Uint8Array = this.stringToUint8Array(content);

      const file: fs.File = fs.openSync(this.cacheFile,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, buffer.buffer);
      fs.closeSync(file);
    } catch (e) {
      console.error(`${REPLAY_CACHE_TAG} Save failed:`, e);
    }
  }

  /** 读取 ReplayPayload，并验证视频文件是否存在 */
  public load(): ReplayPayload | null {
    try {
      if (!this.cacheFile) {
        return null;
      }
      if (fs.accessSync(this.cacheFile)) {
        const file: fs.File = fs.openSync(this.cacheFile, fs.OpenMode.READ_ONLY);
        const size: number = fs.statSync(this.cacheFile).size;
        const buffer: Uint8Array = new Uint8Array(size);

        fs.readSync(file.fd, buffer.buffer);
        fs.closeSync(file);

        const content: string = this.uint8ArrayToString(buffer);
        const payload = JSON.parse(content) as ReplayPayload;
        
        // 验证视频文件是否仍然存在
        if (payload.videoPath && payload.videoPath.length > 0) {
          try {
            if (fs.accessSync(payload.videoPath)) {
              const videoStat = fs.statSync(payload.videoPath);
              const videoSize = videoStat && typeof videoStat.size === 'number' ? videoStat.size : 0;
              if (videoSize > 0) {
                payload.videoSizeBytes = videoSize;
              } else {
                payload.videoPath = undefined;
                payload.videoSizeBytes = undefined;
              }
            } else {
              payload.videoPath = undefined;
              payload.videoSizeBytes = undefined;
            }
          } catch (_) {
            payload.videoPath = undefined;
            payload.videoSizeBytes = undefined;
          }
        }
        
        return payload;
      }
    } catch (_) {
    }
    return null;
  }

  /** 清理缓存文件（包括缓存的视频文件） */
  public clear(): void {
    try {
      if (this.cacheFile && fs.accessSync(this.cacheFile)) {
        fs.unlinkSync(this.cacheFile);
      }
      if (this.ongoingFile && fs.accessSync(this.ongoingFile)) {
        fs.unlinkSync(this.ongoingFile);
      }
      // 清理缓存的视频文件
      if (this.cachedVideoFile) {
        try {
          if (fs.accessSync(this.cachedVideoFile)) {
            fs.unlinkSync(this.cachedVideoFile);
          }
        } catch (_) {}
      }
    } catch (_) {
    }
  }

  /** 持久化当前段的元数据，便于下次启动补发 */
  public persistSegmentValue(key: string, value?: string): void {
    try {
      if (!this.ongoingFile) return;
      let map = new Map<string, string>();
      if (fs.accessSync(this.ongoingFile)) {
        const file: fs.File = fs.openSync(this.ongoingFile, fs.OpenMode.READ_WRITE);
        const size: number = fs.statSync(this.ongoingFile).size;
        const buffer: Uint8Array = new Uint8Array(size);
        fs.readSync(file.fd, buffer.buffer);
        fs.closeSync(file);
        const content = this.uint8ArrayToString(buffer);
        content.split('\n').forEach(line => {
          const idx = line.indexOf('=');
          if (idx > 0) {
            const k = line.substring(0, idx);
            const v = line.substring(idx + 1);
            map.set(k, v);
          }
        });
      }
      if (value === undefined || value === null) {
        map.delete(key);
      } else {
        map.set(key, value);
      }
      const entries = Array.from(map.entries());
      const kv: string[] = [];
      for (let i = 0; i < entries.length; i++) {
        const pair = entries[i];
        const k = pair[0];
        const v = pair[1];
        kv.push(`${k}=${v}`);
      }
      const out = kv.join('\n');
      const file: fs.File = fs.openSync(this.ongoingFile,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, this.stringToUint8Array(out).buffer);
      fs.closeSync(file);
    } catch (e) {
      // ignore
    }
  }

  /** 读取 .ongoing_segment 简易 KV */
  public loadOngoing(): Map<string, string> | null {
    try {
      if (!this.ongoingFile) return null;
      if (!fs.accessSync(this.ongoingFile)) return null;
      const file: fs.File = fs.openSync(this.ongoingFile, fs.OpenMode.READ_ONLY);
      const size: number = fs.statSync(this.ongoingFile).size;
      const buffer: Uint8Array = new Uint8Array(size);
      fs.readSync(file.fd, buffer.buffer);
      fs.closeSync(file);
      const content = this.uint8ArrayToString(buffer);
      const map = new Map<string, string>();
      content.split('\n').forEach(line => {
        const idx = line.indexOf('=');
        if (idx > 0) {
          map.set(line.substring(0, idx), line.substring(idx + 1));
        }
      });
      return map;
    } catch (_) {
      return null;
    }
  }

  /** 删除缓存目录（含 .ongoing_segment） */
  public cleanupAll(): void {
    this.clear();
  }
}

