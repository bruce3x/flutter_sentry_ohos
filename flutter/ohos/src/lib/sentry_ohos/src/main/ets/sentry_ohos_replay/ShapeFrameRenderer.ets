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
import { ShapeFrame, ShapeFramePageInfo, ShapePrimitive, ShapeRect } from './ShapeFrameBuilder';

const GLYPH_WIDTH: number = 5;
const GLYPH_HEIGHT: number = 7;
const GLYPH_SPACING: number = 1;

const FONT_5X7: Record<string, number[]> = {
  '0': [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110],
  '1': [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
  '2': [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111],
  '3': [0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110],
  '4': [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010],
  '5': [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110],
  '6': [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110],
  '7': [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b10000],
  '8': [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110],
  '9': [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100],
  'A': [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
  'B': [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110],
  'C': [0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110],
  'D': [0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110],
  'E': [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111],
  'F': [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000],
  'G': [0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111],
  'H': [0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
  'I': [0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
  'J': [0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100],
  'K': [0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001],
  'L': [0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111],
  'M': [0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001],
  'N': [0b10001, 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001],
  'O': [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
  'P': [0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000],
  'Q': [0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101],
  'R': [0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001],
  'S': [0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110],
  'T': [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100],
  'U': [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
  'V': [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100],
  'W': [0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010],
  'X': [0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001],
  'Y': [0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100],
  'Z': [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111],
  ' ': [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000],
  '-': [0b00000, 0b00000, 0b00000, 0b01110, 0b00000, 0b00000, 0b00000],
  '_': [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b11111],
  '.': [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b01100],
  '/': [0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b00000, 0b00000],
  ':': [0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b01100, 0b00000],
  '[': [0b01110, 0b01000, 0b01000, 0b01000, 0b01000, 0b01000, 0b01110],
  ']': [0b01110, 0b00010, 0b00010, 0b00010, 0b00010, 0b00010, 0b01110],
  '(': [0b00110, 0b01000, 0b10000, 0b10000, 0b10000, 0b01000, 0b00110],
  ')': [0b01100, 0b00010, 0b00001, 0b00001, 0b00001, 0b00010, 0b01100],
  '#': [0b01010, 0b11111, 0b01010, 0b01010, 0b11111, 0b01010, 0b01010],
  '@': [0b01110, 0b10001, 0b10111, 0b10111, 0b10110, 0b10000, 0b01110],
  '?': [0b01110, 0b10001, 0b00001, 0b00110, 0b00100, 0b00000, 0b00100]
};

const FONT_DEFAULT_GLYPH: number[] = FONT_5X7['?'];

export interface RenderSize { width: number; height: number }

/**
 * 将形状帧渲染为 PixelMap（ARGB8888），用于后续编码。
 * 注意：ArkTS 暂无稳定的 2D Canvas 离屏 API 统一层，这里采用像素缓冲直写渲染简单轮廓。
 */
export class ShapeFrameRenderer {
  private readonly backgroundColor: number;
  private readonly fallbackFillColor: number;
  private readonly fallbackStrokeColor: number;
  private readonly pageBannerColor: number;
  private readonly pageTextColor: number;

  constructor(background: string = '#FF111216', fill: string = '#FF2C2F36', stroke: string = '#40FFFFFF') {
    this.backgroundColor = this.parseColor(background);
    this.fallbackFillColor = this.parseColor(fill);
    this.fallbackStrokeColor = this.parseColor(stroke);
    this.pageBannerColor = this.parseColor('#CC1F232A');
    this.pageTextColor = this.parseColor('#FFFFFFFF');
  }

  public async renderToPixelMap(frame: ShapeFrame, size: RenderSize): Promise<image.PixelMap> {
    const opts: image.InitializationOptions = {
      size: { width: size.width, height: size.height },
      pixelFormat: image.PixelMapFormat.ARGB_8888,
      alphaType: 1, // UNPREMUL
      editable: true
    } as image.InitializationOptions;
    const buffer = new ArrayBuffer(size.width * size.height * 4);
    const pm = await image.createPixelMap(buffer, opts);

    const width = size.width;
    const height = size.height;
    const pixels = new Uint8Array(width * height * 4);

    this.fillRect(pixels, width, height, 0, 0, width, height, this.backgroundColor);

    if (frame.pages && frame.pages.length > 0) {
      this.drawPagesOverlay(pixels, width, height, frame.pages);
    }

    for (let i = 0; i < frame.shapes.length; i++) {
      const s: ShapePrimitive = frame.shapes[i];
      if ((s as ShapeRect).type === 'rect' || (s as ShapeRect).type === 'roundRect') {
        const r = s as ShapeRect;
        const fillColor = this.applyOpacity(this.parseColor(r.style?.fillColor ?? ''), r.style?.opacity, this.fallbackFillColor);
        const strokeColor = this.applyOpacity(this.parseColor(r.style?.strokeColor ?? ''), r.style?.opacity, this.fallbackStrokeColor);
        const strokeWidth = Math.max(1, Math.floor(r.style?.strokeWidth ?? 1));
        this.fillRect(pixels, width, height, Math.floor(r.x), Math.floor(r.y), Math.floor(r.width), Math.floor(r.height), fillColor);
        this.strokeRect(pixels, width, height, Math.floor(r.x), Math.floor(r.y), Math.floor(r.width), Math.floor(r.height), strokeColor, strokeWidth);
      }
    }

    pm.writePixels({ pixels, offset: 0, stride: width * 4, region: { x: 0, y: 0, size: { width, height } } });
    return pm;
  }

  private fillRect(buffer: Uint8Array, width: number, height: number, x: number, y: number, w: number, h: number, argb: number): void {
    if (w <= 0 || h <= 0) { return; }
    const a = (argb >>> 24) & 0xFF;
    const r = (argb >>> 16) & 0xFF;
    const g = (argb >>> 8) & 0xFF;
    const b = argb & 0xFF;
    const xStart = Math.max(0, x);
    const yStart = Math.max(0, y);
    const xEnd = Math.min(width, x + w);
    const yEnd = Math.min(height, y + h);
    for (let py = yStart; py < yEnd; py++) {
      const rowOffset = py * width;
      for (let px = xStart; px < xEnd; px++) {
        const idx = (rowOffset + px) * 4;
        buffer[idx] = a;
        buffer[idx + 1] = r;
        buffer[idx + 2] = g;
        buffer[idx + 3] = b;
      }
    }
  }

  private strokeRect(buffer: Uint8Array, width: number, height: number, x: number, y: number, w: number, h: number, argb: number, strokeWidth: number): void {
    if (w <= 0 || h <= 0 || strokeWidth <= 0) { return; }
    const half = Math.floor(strokeWidth / 2);
    const a = (argb >>> 24) & 0xFF;
    const r = (argb >>> 16) & 0xFF;
    const g = (argb >>> 8) & 0xFF;
    const b = argb & 0xFF;
    const put = (px: number, py: number) => {
      if (px < 0 || py < 0 || px >= width || py >= height) return;
      const idx = (py * width + px) * 4;
      buffer[idx] = a;
      buffer[idx + 1] = r;
      buffer[idx + 2] = g;
      buffer[idx + 3] = b;
    };
    const left = x - half;
    const right = x + w - 1 + half;
    const top = y - half;
    const bottom = y + h - 1 + half;
    for (let px = left; px <= right; px++) {
      for (let sw = 0; sw < strokeWidth; sw++) {
        put(px, top + sw);
        put(px, bottom - sw);
      }
    }
    for (let py = top; py <= bottom; py++) {
      for (let sw = 0; sw < strokeWidth; sw++) {
        put(left + sw, py);
        put(right - sw, py);
      }
    }
  }

  private parseColor(hex: string): number {
    // 支持 #RRGGBB 或 #AARRGGBB
    let s = hex.startsWith('#') ? hex.substring(1) : hex;
    if (s.length === 6) {
      s = 'FF' + s; // 默认不透明
    }
    if (s.length !== 8) {
      return this.fallbackFillColor;
    }
    return parseInt(s, 16);
  }

  private applyOpacity(color: number, opacity: number | undefined, fallback: number): number {
    const base = Number.isFinite(color) ? color : fallback;
    const alpha = (base >>> 24) & 0xFF;
    const factor = opacity !== undefined ? Math.max(0, Math.min(1, opacity)) : 1;
    const finalAlpha = Math.floor(alpha * factor) & 0xFF;
    return (finalAlpha << 24) | (base & 0x00FFFFFF);
  }

  private drawPagesOverlay(buffer: Uint8Array, width: number, height: number, pages: ShapeFramePageInfo[]): void {
    if (pages.length === 0) {
      return;
    }
    const lineHeight = 12;
    const bannerHeight = Math.min(height, Math.max(24, pages.length * lineHeight + 10));
    this.fillRect(buffer, width, height, 0, 0, width, bannerHeight, this.pageBannerColor);
    const maxLineWidth = width - 16;
    for (let i = 0; i < pages.length; i++) {
      const page = pages[i];
      const indexLabel = (i + 1).toString();
      const stateSuffix = page.state && page.state.length > 0 ? ' [' + page.state + ']' : '';
      const rawLabel = indexLabel + '. ' + page.name + stateSuffix;
      const safeLabel = this.truncateForWidth(rawLabel, maxLineWidth);
      this.drawText(buffer, width, height, 8, 6 + (i * lineHeight), safeLabel, this.pageTextColor);
    }
  }

  private truncateForWidth(text: string, maxWidthPixels: number): string {
    const upper = text.toUpperCase();
    const glyphAdvance = GLYPH_WIDTH + GLYPH_SPACING;
    if (maxWidthPixels <= glyphAdvance) {
      return upper.substring(0, 1);
    }
    const maxChars = Math.max(1, Math.floor(maxWidthPixels / glyphAdvance));
    if (upper.length <= maxChars) {
      return upper;
    }
    if (maxChars <= 3) {
      return upper.substring(0, maxChars);
    }
    return upper.substring(0, maxChars - 3) + '...';
  }

  private drawText(buffer: Uint8Array, width: number, height: number, x: number, y: number, text: string, argb: number): void {
    const sanitized = text.toUpperCase();
    let cursorX = x;
    for (let i = 0; i < sanitized.length; i++) {
      const ch = sanitized.charAt(i);
      const glyph = FONT_5X7[ch] || FONT_DEFAULT_GLYPH;
      this.blitGlyph(buffer, width, height, cursorX, y, glyph, argb);
      cursorX += GLYPH_WIDTH + GLYPH_SPACING;
      if (cursorX >= width) {
        break;
      }
    }
  }

  private blitGlyph(buffer: Uint8Array, width: number, height: number, x: number, y: number, glyph: number[], argb: number): void {
    const a = (argb >>> 24) & 0xFF;
    const r = (argb >>> 16) & 0xFF;
    const g = (argb >>> 8) & 0xFF;
    const b = argb & 0xFF;
    for (let row = 0; row < GLYPH_HEIGHT; row++) {
      if (row + y < 0 || row + y >= height) {
        continue;
      }
      const rowBits = row < glyph.length ? glyph[row] : 0;
      for (let col = 0; col < GLYPH_WIDTH; col++) {
        if (col + x < 0 || col + x >= width) {
          continue;
        }
        const mask = 1 << (GLYPH_WIDTH - 1 - col);
        if ((rowBits & mask) !== 0) {
          const idx = ((y + row) * width + (x + col)) * 4;
          buffer[idx] = a;
          buffer[idx + 1] = r;
          buffer[idx + 2] = g;
          buffer[idx + 3] = b;
        }
      }
    }
  }
}


