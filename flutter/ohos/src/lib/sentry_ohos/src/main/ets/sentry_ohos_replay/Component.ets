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

import { BaseUIEvent } from "./BaseUIEvent";


export interface UIComponent {
  id: string;

  onTouch(callback: (event: BaseUIEvent) => void): void;

  // 可选：如果你的控件支持取消订阅，建议实现 offTouch，便于 stopCapture 时解绑
  offTouch?: (callback: (event: BaseUIEvent) => void) => void;

  // ArkUI 官方手势回调（可选，适配层提供）
  onTap?: (callback: (x: number, y: number) => void) => void;
  onLongPress?: (callback: (x: number, y: number, durationMs?: number) => void) => void;
  onPan?: (callback: (dx: number, dy: number, velocityX?: number, velocityY?: number) => void) => void;
  onPinch?: (callback: (scale: number, centerX?: number, centerY?: number) => void) => void;
  onRotate?: (callback: (angle: number, centerX?: number, centerY?: number) => void) => void;
  onSwipe?: (callback: (direction: 'Left' | 'Right' | 'Up' | 'Down') => void) => void;
  // 解绑可选
  offTap?: (callback: (x: number, y: number) => void) => void;
  offLongPress?: (callback: (x: number, y: number, durationMs?: number) => void) => void;
  offPan?: (callback: (dx: number, dy: number, velocityX?: number, velocityY?: number) => void) => void;
  offPinch?: (callback: (scale: number, centerX?: number, centerY?: number) => void) => void;
  offRotate?: (callback: (angle: number, centerX?: number, centerY?: number) => void) => void;
  offSwipe?: (callback: (direction: 'Left' | 'Right' | 'Up' | 'Down') => void) => void;
}

export interface TextInputComponent extends UIComponent {
  onChange(callback: (value: string) => void): void;
  onFocus(callback: () => void): void;
  onBlur(callback: () => void): void;
  offChange?: (callback: (value: string) => void) => void;
  offFocus?: (callback: () => void) => void;
  offBlur?: (callback: () => void) => void;
}
