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

import { SnapshotEventData } from "./ViewSnapshot";

/**
 * 捕获的用户操作事件数据模型
 */
export interface ReplayEvent {
  type: "touch" | "tap" | "longpress" | "pan" | "pinch" | "rotate" | "swipe" | "input" | "focus" | "blur" | "scroll" | "snapshot";
  timestamp: number;
  data: ReplayEventData;
}

/**
 * 不同事件的数据模型
 */
export type ReplayEventData =
  | TouchEventData
  | TapEventData
  | LongPressEventData
  | PanEventData
  | PinchEventData
  | RotateEventData
  | SwipeEventData
  | InputEventData
  | FocusEventData
  | BlurEventData
  | ScrollEventData
  | SnapshotEventData;

/**
 * 触摸事件
 */
export interface TouchEventData {
  componentId: string;
  x: number;
  y: number;
  action: "down" | "up" | "move" | "longPress";
}

export interface TapEventData { componentId: string; x: number; y: number }
export interface LongPressEventData { componentId: string; x: number; y: number; durationMs?: number }
export interface PanEventData { componentId: string; dx: number; dy: number; velocityX?: number; velocityY?: number }
export interface PinchEventData { componentId: string; scale: number; centerX?: number; centerY?: number }
export interface RotateEventData { componentId: string; angle: number; centerX?: number; centerY?: number }
export interface SwipeEventData { componentId: string; direction: 'Left' | 'Right' | 'Up' | 'Down' }

/**
 * 文本输入事件
 */
export interface InputEventData {
  componentId: string;
  value: string;
}

/**
 * 获取焦点事件
 */
export interface FocusEventData {
  componentId: string;
}

/**
 * 失去焦点事件
 */
export interface BlurEventData {
  componentId: string;
}

/**
 * 滚动事件
 */
export interface ScrollEventData {
  componentId: string;
  scrollX: number;
  scrollY: number;
}

