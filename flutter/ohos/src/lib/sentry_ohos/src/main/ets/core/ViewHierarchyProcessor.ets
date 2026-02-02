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
import fileio from '@ohos.fileio';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import { ViewRegistry, ViewTreeSnapshot, ViewNode } from './ViewRegistry';

export interface ProcessorOptions {
  maxNodes: number;
  maxDepth: number;
  includeText: boolean;
  screenshotEnabled: boolean;
}

export interface ViewHierarchyOut {
  tree?: ViewTreeSnapshot;
  screenshotPath?: string;
}

// PixelMap/Window 快照的最小类型定义
interface PixelMapLike {}
interface PixelMapWithRelease extends PixelMapLike { release: () => void }
interface HarmonyWindowSnap { snapshot: () => Promise<PixelMapLike> }

interface GeneratedObjectLiteralInterface_1 {
  format: string;
  quality: number;
}

interface ImagePackerLike {
  packing(pixelMap: PixelMapLike, options: GeneratedObjectLiteralInterface_1, callback: (err: Error | undefined, data: ArrayBuffer) => void): void;
}

export class ViewHierarchyProcessor {
  async build(context: common.BaseContext | undefined, outDir: string, options: ProcessorOptions): Promise<ViewHierarchyOut> {
    const out: ViewHierarchyOut = {};
    try {
      const tree = ViewRegistry.get().snapshot();
      const pruned = this.prune(tree, options.maxNodes, options.maxDepth, options.includeText);
      out.tree = pruned;
    } catch (_) {}

    if (options.screenshotEnabled && context) {
      try {
        const path = await this.captureWindowToPng(context, `${outDir}/vh_${Date.now()}.png`);
        out.screenshotPath = path;
      } catch (_) {}
    }
    return out;
  }

  private prune(tree: ViewTreeSnapshot, maxNodes: number, maxDepth: number, includeText: boolean): ViewTreeSnapshot {
    // 简化版：仅裁剪节点数，不做复杂遍历（骨架占位）
    const ids = Object.keys(tree.nodes);
    const limited = ids.slice(0, maxNodes);
    const nodesOut: Record<string, ViewNode> = {};
    for (let i = 0; i < limited.length; i++) {
      const id = limited[i];
      const n = tree.nodes[id];
      const clone: ViewNode = {
        id: n.id,
        type: n.type,
        bounds: n.bounds,
        visible: n.visible,
        opacity: n.opacity,
        testId: n.testId,
        text: includeText ? n.text : undefined,
        children: n.children.filter(cid => limited.indexOf(cid) >= 0),
        parentId: n.parentId && limited.indexOf(n.parentId) >= 0 ? n.parentId : undefined,
      };
      nodesOut[id] = clone;
    }
    const rootIds = tree.rootIds.filter(id => limited.indexOf(id) >= 0);
    return { rootIds: rootIds, nodes: nodesOut } as ViewTreeSnapshot;
  }

  private async captureWindowToPng(context: common.BaseContext, filePath: string): Promise<string> {
    const win = await window.getLastWindow(context);
    const pixelMap = await (win as HarmonyWindowSnap).snapshot();
    const packer = image.createImagePacker();
    const pngBuffer: ArrayBuffer = await new Promise<ArrayBuffer>((resolve) => {
      const opts: GeneratedObjectLiteralInterface_1 = { format: 'image/png', quality: 100 };
      // 使用回调重载，避免 Promise/void 重载歧义
      (packer as ImagePackerLike).packing(pixelMap, opts, (err: Error | undefined, data: ArrayBuffer) => {
        if (err) {
          resolve(new ArrayBuffer(0));
        } else {
          resolve(data);
        }
      });
    });
    // PNG 健壮性修正：
    // 1) 确保 8..11 (IHDR length) 为 00 00 00 0D
    // 2) 若出现异常的 0x20 空格字节污染宽高字段（16..19 宽，20..23 高），将 0x20 纠正为 0x00
    try {
      const u8 = new Uint8Array(pngBuffer);
      if (u8.byteLength >= 16) {
        const sigOk = (u8[0] === 0x89 && u8[1] === 0x50 && u8[2] === 0x4E && u8[3] === 0x47 && u8[4] === 0x0D && u8[5] === 0x0A && u8[6] === 0x1A && u8[7] === 0x0A);
        const ihdr = (u8[12] === 0x49 && u8[13] === 0x48 && u8[14] === 0x44 && u8[15] === 0x52);
        const badLen = (u8[8] === 0x20 || u8[9] === 0x20 || u8[10] === 0x20);
        if (sigOk && ihdr && badLen) {
          u8[8] = 0x00; u8[9] = 0x00; u8[10] = 0x00; u8[11] = 0x0D;
        }
        // 宽高字段位于 IHDR 数据段的前 8 字节（大端）：
        // width:  16..19, height: 20..23
        if (sigOk && ihdr && u8.byteLength >= 24) {
          // 将可能出现的 0x20 空格（ASCII 空格）修正为 0x00，避免解析失败
          // 仅对高位常为 0 的场景作修正（常见手机分辨率 < 65536）
          if (u8[16] === 0x20) u8[16] = 0x00;
          if (u8[17] === 0x20) u8[17] = 0x00;
          if (u8[20] === 0x20) u8[20] = 0x00;
          if (u8[21] === 0x20) u8[21] = 0x00;
        }
      }
    } catch (_) {}
    const dir = filePath.substring(0, filePath.lastIndexOf('/'));
    this.ensureDirSync(dir);
    const O_CREAT = 0o100; // create if not exists
    const O_RDWR = 0o2;    // read/write
    const fd = fileio.openSync(filePath, O_CREAT | O_RDWR, 0o666);
    fileio.writeSync(fd, new Uint8Array(pngBuffer));
    fileio.closeSync(fd);
    const rel = (pixelMap as PixelMapWithRelease).release;
    if (typeof rel === 'function') (pixelMap as PixelMapWithRelease).release();
    return filePath;
  }

  private ensureDirSync(dirPath: string): void {
    try {
      fileio.mkdirSync(dirPath);
    } catch (_) {
      // 目录可能已存在
    }
  }
}


