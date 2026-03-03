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

export interface ShapeStyle {
  fillColor?: string; // e.g. #RRGGBBAA
  strokeColor?: string;
  strokeWidth?: number;
  radius?: number; // corner radius for round rect
  opacity?: number; // 0..1
}

export interface ShapeRect {
  type: 'rect' | 'roundRect';
  x: number;
  y: number;
  width: number;
  height: number;
  style?: ShapeStyle;
}

export type ShapePrimitive = ShapeRect; // can extend with circle/path later

export interface ShapeFramePageInfo {
  name: string;
  state?: string;
}

export interface ShapeFrame {
  timestamp: number;
  shapes: ShapePrimitive[];
  pages?: ShapeFramePageInfo[];
}

export interface ComponentLayoutInfo {
  id: string;
  x: number;
  y: number;
  width: number;
  height: number;
  radius?: number;
}

export class ShapeFrameBuilder {
  private defaultStyle: ShapeStyle;

  constructor(defaultStyle?: ShapeStyle) {
    this.defaultStyle = defaultStyle || { fillColor: '#662C2F36', strokeColor: '#80FFFFFF', strokeWidth: 1, radius: 8, opacity: 1 };
  }

  public buildFrame(layouts: ComponentLayoutInfo[], ts?: number, pages?: ShapeFramePageInfo[]): ShapeFrame {
    const timestamp = ts !== undefined ? ts : Date.now();
    const shapes: ShapePrimitive[] = [];
    for (let i = 0; i < layouts.length; i++) {
      const l = layouts[i];
      const style: ShapeStyle = {
        fillColor: this.defaultStyle.fillColor,
        strokeColor: this.defaultStyle.strokeColor,
        strokeWidth: this.defaultStyle.strokeWidth,
        radius: l.radius !== undefined ? l.radius : this.defaultStyle.radius,
        opacity: this.defaultStyle.opacity,
      };
      const s: ShapeRect = {
        type: (style.radius && style.radius > 0) ? 'roundRect' : 'rect',
        x: l.x,
        y: l.y,
        width: l.width,
        height: l.height,
        style: style,
      };
      shapes.push(s);
    }
    const frame: ShapeFrame = { timestamp, shapes };
    if (pages && pages.length > 0) {
      frame.pages = pages.slice();
    }
    return frame;
  }
}
