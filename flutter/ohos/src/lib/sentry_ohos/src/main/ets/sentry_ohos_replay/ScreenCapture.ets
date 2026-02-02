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

import window from '@ohos.window';
import image from '@ohos.multimedia.image';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';

export interface ScreenEventData {
  // 运行期存文件，上传前再读取为 base64
  filePath?: string;
  imageBase64?: string;
  width: number;
  height: number;
  timestamp: number;
}

// 屏幕捕获
export class ScreenCapture {
  /**
   * 捕获屏幕并返回 ScreenEventData 数组
   * @param context 应用上下文
   */
  public async captureScreen(context: common.BaseContext): Promise<ScreenEventData[]> {
    try {
      const win = await window.getLastWindow(context); // ArkUI 提供的截图 API
      const pixelMap = await win.snapshot();
      const imageInfo = (await pixelMap.getImageInfo()).size;
      const width: number = imageInfo.width;
      const height: number = imageInfo.height;

      // 压缩为 JPEG 并落盘，避免将大图片常驻内存
      const packer = image.createImagePacker();
      const packOpts: image.PackingOption = {
        format: 'image/jpeg',
        quality: 60
      } as image.PackingOption;
      const buffer: ArrayBuffer = await packer.packing(pixelMap, packOpts);

      const baseDir = this.resolveBaseDir(context);
      if (!baseDir) {
        return [];
      }
      const framesDir = `${baseDir}/replay_frames`;
      try {
        if (!fs.accessSync(framesDir)) {
          fs.mkdirSync(framesDir);
        }
      } catch (_) {}
      const ts = Date.now();
      const filePath = `${framesDir}/frame_${ts}.jpg`;
      const file = fs.openSync(filePath, 0o666);
      fs.writeSync(file.fd, buffer);
      fs.closeSync(file);
      // 可选释放 pixelMap（部分版本支持）
      try {
        interface PixelMapReleasable { release?: () => void }
        const pm = pixelMap as PixelMapReleasable;
        if (typeof pm.release === 'function') pm.release();
      } catch (_) {}

      return [{
        filePath,
        width,
        height,
        timestamp: ts
      }];
    } catch (e) {
      console.error("ScreenCapture 捕获屏幕失败:", e);
      return [];
    }
  }

  private resolveBaseDir(ctx: common.BaseContext): string | undefined {
    interface FileDirProvider { filesDir?: string; cacheDir?: string; }
    const p = ctx as FileDirProvider;
    return p.filesDir ?? p.cacheDir;
  }
}
