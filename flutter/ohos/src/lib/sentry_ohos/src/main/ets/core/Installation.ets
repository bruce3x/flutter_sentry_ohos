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
import util from '@ohos.util';

export class Installation {
  // 缓存 installationId
  private static _installationId: string | undefined = undefined;

  /**
   * 获取或生成 Installation ID (同步)
   * 对齐 Android Installation.id(context) 逻辑：持久化存储的随机 UUID
   */
  public static id(): string {
    if (Installation._installationId) {
      return Installation._installationId;
    }
    // 使用应用私有文件路径存储 INSTALLATION 文件
    // 注意：路径硬编码适配当前 HarmonyOS 应用结构
    const filesDir = '/data/storage/el2/base/haps/entry/files';
    const installPath = `${filesDir}/INSTALLATION`;

    try {
      // 1. 尝试读取现有 ID
      if (fs.accessSync(installPath)) {
        // 使用 fileio 读取文本
        const stream = fs.createStreamSync(installPath, "r");
        const buf = new ArrayBuffer(4096);
        const readLen = stream.readSync(buf);
        stream.closeSync();
        if (readLen > 0) {
          const decoder = new util.TextDecoder();
          const content = decoder.decodeWithStream(new Uint8Array(buf.slice(0, readLen)));
          if (content && content.length > 0) {
            Installation._installationId = content.trim();
            return Installation._installationId!;
          }
        }
      }
    } catch (_) {}

    // 2. 生成新的 UUID
    try {
      let uuid = '';
      try {
        uuid = util.generateRandomUUID(true);
      } catch (_) {
        uuid = util.generateRandomUUID(); // 尝试默认
      }

      Installation._installationId = uuid;

      // 3. 写入文件
      try {
        if (!fs.accessSync(filesDir)) {
          fs.mkdirSync(filesDir);
        }
        const file = fs.openSync(installPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, uuid);
        fs.closeSync(file);
      } catch (e) {
        console.error('[Sentry] Failed to save installation ID: ' + (e?.message || String(e)));
      }
      return uuid;
    } catch (e) {
      console.error('[Sentry] Failed to generate installation ID: ' + (e?.message || String(e)));
      // Fallback: 简易随机 ID
      return 'EMULATED-' + Math.random().toString(36).substring(2) + Date.now().toString(36);
    }
  }
}
