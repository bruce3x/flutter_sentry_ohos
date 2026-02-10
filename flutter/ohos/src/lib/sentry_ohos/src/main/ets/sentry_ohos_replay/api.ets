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

import common from '@ohos.app.ability.common';
import { ReplayController } from './ReplayController';
import { ComponentLayoutInfo } from './ShapeFrameBuilder';
import { SamplingConfig } from './SamplingConfig';
import { SessionManager } from './SessionManager';
import { UIComponent, TextInputComponent } from './Component';

export interface ReplayStartOptions {
  context: common.BaseContext;
  serverUrl: string;
  maskAllText?: boolean; // 预留，当前在 PrivacyConfig 内部处理
  frameIntervalMs?: number; // 例如 500ms → 2fps（与 SamplingConfig.frameRate 对齐）
  segmentMs?: number; // 例如 5000ms 一段
  bufferMode?: boolean; // true: 缓冲模式（错误触发上传），false: 会话模式（持续分段上传）。若省略则由采样决定
  sessionSampleRate?: number; // 对齐 Android：全会话采样率 [0,1]
  onErrorSampleRate?: number; // 对齐 Android：错误回放采样率 [0,1]
  maskAllImages?: boolean; // 全局遮罩图片（页面快照/屏幕帧）
  uiComponents?: UIComponent[]; // 需采集手势事件的组件
  textInputs?: TextInputComponent[]; // 需采集输入事件的组件
  enableScreenFrames?: boolean; // 是否上传像素级屏幕帧，默认关闭
}

export interface ConfigureSamplingOptions {
  frameIntervalMs?: number;
  segmentMs?: number;
}

let controller: ReplayController | undefined;
let replaySessionManager: SessionManager | undefined;

export function startReplay(opts: ReplayStartOptions): void {
  if (!controller) {
    // 采样驱动的模式选择：若未显式传入 bufferMode，则根据采样率决定
    let resolvedBufferMode: boolean = false;
    if (typeof opts.bufferMode === 'boolean') {
      resolvedBufferMode = opts.bufferMode;
    } else {
      const sessionRate = Math.max(0, Math.min(opts.sessionSampleRate ?? 0, 1));
      const onErrorRate = Math.max(0, Math.min(opts.onErrorSampleRate ?? 0, 1));
      const fullSession = Math.random() < sessionRate;
      resolvedBufferMode = fullSession ? false : (onErrorRate > 0);
    }
    controller = new ReplayController({
      uiComponents: opts.uiComponents ?? [],
      textInputs: opts.textInputs ?? [],
      autoStart: true,
      bufferMode: resolvedBufferMode,
      serverUrl: opts.serverUrl,
      sessionSampleRate: opts.sessionSampleRate,
      onErrorSampleRate: opts.onErrorSampleRate,
      enableScreenFrames: opts.enableScreenFrames === true ? true : false
    });
    replaySessionManager = new SessionManager();
  }
  // 采样参数
  const frameRate = (opts.frameIntervalMs && opts.frameIntervalMs > 0) ? Math.max(1, Math.floor(1000 / opts.frameIntervalMs)) : 2;
  const segmentMs = (opts.segmentMs && opts.segmentMs > 0) ? opts.segmentMs : 5000;
  controller.configureSampling(frameRate, segmentMs);
  controller.updateContext(opts.context);
  if (typeof opts.maskAllText === 'boolean') {
    controller.setMaskAllText(opts.maskAllText);
  }
  if (typeof opts.maskAllImages === 'boolean') {
    controller.setMaskAllImages(opts.maskAllImages);
  }
  controller.start();
}

export function stopReplay(): void {
  if (controller) controller.stop();
}

export function getReplayId(): string | undefined {
  if (controller) return controller.getCurrentSessionId();
  return undefined;
}

export function pauseReplay(): void {
  if (controller) controller.pause();
}

export function resumeReplay(): void {
  if (controller) controller.resume();
}

export function onAppForeground(): void {
  if (controller) controller.onAppForeground();
}

export async function onAppBackground(): Promise<void> {
  if (controller) await controller.onAppBackground();
}

export function updateReplayContext(ctx: common.BaseContext): void {
  if (controller) controller.updateContext(ctx);
}

// UI 侧提供布局信息（x/y/width/height/radius）以生成形状帧
export function updateReplayLayouts(layouts: ComponentLayoutInfo[]): void {
  if (!controller) return;
  // 直接透传到控制器（控制器内部将使用最新布局构建 snapshot 的形状帧）
  try { (controller as ReplayController).__setLayouts(layouts); } catch (_) {}
}

export function configureReplaySampling(opts: ConfigureSamplingOptions): void {
  if (!controller) return;
  const frameRate = (opts.frameIntervalMs && opts.frameIntervalMs > 0) ? Math.max(1, Math.floor(1000 / opts.frameIntervalMs)) : undefined;
  const segmentMs = (opts.segmentMs && opts.segmentMs > 0) ? opts.segmentMs : undefined;
  controller.configureSampling(frameRate, segmentMs);
}

export async function uploadReplay(serverUrl: string, ctx: common.BaseContext): Promise<boolean> {
  if (!controller) return false;
  return await controller.uploadReplay(serverUrl, ctx);
}

export async function captureReplayOnError(ctx: common.BaseContext, errorEventId?: string): Promise<boolean> {
  if (!controller) return false;
  return await controller.captureReplayOnError(ctx, errorEventId);
}

export function setReplayConnectionStatus(connected: boolean): void {
  if (controller) controller.setConnectionStatus(connected);
}

export function setReplayRateLimited(rateLimited: boolean): void {
  if (controller) controller.setRateLimited(rateLimited);
}

export function pushFlutterFrame(buffer: ArrayBuffer, width: number, height: number, stride: number, timestamp: number): void {
  if (!controller) {
    return;
  }
  try {
    controller.enqueueFlutterFrame(buffer, width, height, stride, timestamp).then(() => {}).catch(() => {});
  } catch (_) {}
}

export function registerReplayComponent(ui: UIComponent, arkComponent: ESObject): void {
  if (controller) controller.registerUIComponentForReplay(ui, arkComponent);
}

export function unregisterReplayComponent(ui: UIComponent): void {
  if (controller) controller.unregisterUIComponentForReplay(ui);
}

export function maskReplayComponent(componentId: string): void {
  if (controller) controller.maskComponent(componentId);
}

export function unmaskReplayComponent(componentId: string): void {
  if (controller) controller.unmaskComponent(componentId);
}

export function setMaskAllText(enabled: boolean): void {
  if (controller) controller.setMaskAllText(enabled);
}

export function setMaskAllImages(enabled: boolean): void {
  if (controller) controller.setMaskAllImages(enabled);
}

export function setReplayScrollingState(isScrolling: boolean): void {
  if (controller) controller.setScrollingState(isScrolling);
}

