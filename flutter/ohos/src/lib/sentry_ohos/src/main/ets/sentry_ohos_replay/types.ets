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
import { ReplayEvent } from "./ReplayEvent";
import type { ShapeFramePageInfo } from "./ShapeFrameBuilder";
import type { RRWebBreadcrumbEvent } from "./rrweb/RRWebBreadcrumbEvent";
import type { RRWebSpanEvent } from "./rrweb/RRWebSpanEvent";

export enum UserActionType {
  Click = "click",
  Swipe = "swipe",
  Move = "move",
  LongPress = "longpress",
  Down = "down",
  Up = "up"
}

export interface UserActionEvent {
  type: UserActionType;
  targetId: string;
  timestamp: number;
  x?: number;
  y?: number;
  dx?: number;
  dy?: number;
  direction?: SwipeDirection;
  duration?: number; // 持续时间 ms（从 down 到 up）
  extra?: string;    // 可放任意短说明
}

export type SwipeDirection = "Left" | "Right" | "Up" | "Down";

export interface SnapshotData {
  layout: string; // legacy; keep for compat
  timestamp: number;
}

// 矢量形状帧（用于替代像素快照）
export interface ShapePrimitiveStyle { fillColor?: string; strokeColor?: string; strokeWidth?: number; radius?: number; opacity?: number }
export interface ShapePrimitiveRect { type: 'rect' | 'roundRect'; x: number; y: number; width: number; height: number; style?: ShapePrimitiveStyle }
export type ShapePrimitive = ShapePrimitiveRect;
export interface ShapeFramePayload { timestamp: number; shapes: ShapePrimitive[]; pages?: ShapeFramePageInfo[] }

export interface ReplayPayload {
  sessionId: string;
  events: ReplayPayloadEvent[];
  // 以下字段用于构建标准 replay_event / replay_recording（Android 对齐）
  replay_id?: string;
  segment_id?: number;
  started_at?: string;           // ISO8601
  finished_at?: string;          // ISO8601
  replay_start_timestamp?: number; // seconds
  timestamp?: number;              // seconds
  urls?: Array<string>;
  replay_type?: string;          // 'session'
  platform?: string;            // 'android'
  error_ids?: Array<string>;
  trace_ids?: Array<string>;
  release?: string;
  environment?: string;
  duration?: number;            // seconds
  durationMs?: number;          // milliseconds
  // 可选：本地 MP4 路径与大小（用于 envelope 中的 replay_recording）
  videoPath?: string;
  videoSizeBytes?: number;
  videoWidth?: number;
  videoHeight?: number;
  videoFrameRate?: number;
}

// RRWeb 兼容类型：面包屑与 span
export type RRWebBreadcrumbEventOut = RRWebBreadcrumbEvent;
export type RRWebSpanEventOut = RRWebSpanEvent;

export type ReplayPayloadEventData =
  | ReplayEvent[]
  | SnapshotEventData[]
  | ShapeFramePayload[]
  | RRWebBreadcrumbEventOut[]
  | RRWebSpanEventOut[];

export interface ReplayPayloadEvent {
  type: "gesture" | "input" | "snapshot" | "breadcrumb" | "span";
  data: ReplayPayloadEventData;
}

export interface ReSession {
  id: string;
  startTime: number;
  endTime?: number;
}

