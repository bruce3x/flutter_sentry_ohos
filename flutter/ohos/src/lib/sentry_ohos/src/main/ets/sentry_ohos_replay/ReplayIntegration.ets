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
import { startReplay, stopReplay, updateReplayContext, captureReplayOnError, getReplayId, configureReplaySampling } from './api';

export interface ReplayIntegrationOptions {
  serverUrl?: string;
  sessionSampleRate?: number;
  onErrorSampleRate?: number;
  enableScreenFrames?: boolean;
}

export class ReplayIntegration {
  private context?: common.BaseContext;
  private options: ReplayIntegrationOptions;

  constructor(ctx: common.BaseContext, options?: ReplayIntegrationOptions) {
    this.context = ctx;
    this.options = options || {} as ReplayIntegrationOptions;
  }

  public install(): void {
    if (!this.context || !this.options.serverUrl) return;
    startReplay({
      context: this.context,
      serverUrl: this.options.serverUrl,
      sessionSampleRate: this.options.sessionSampleRate,
      onErrorSampleRate: this.options.onErrorSampleRate,
      enableScreenFrames: this.options.enableScreenFrames === true ? true : false,
    });
  }

  public onConfigurationChanged(config: Record<string, number | undefined>): void {
    const frameRate = config.frameRate;
    if (typeof frameRate === 'number' && frameRate > 0) {
      const frameIntervalMs = Math.max(1, Math.floor(1000 / frameRate));
      configureReplaySampling({ frameIntervalMs: frameIntervalMs });
    }
    if (typeof config.segmentMs === 'number' && config.segmentMs > 0) {
      configureReplaySampling({ segmentMs: config.segmentMs as number });
    }
  }

  public setContext(ctx: common.BaseContext): void {
    this.context = ctx;
    updateReplayContext(ctx);
    // 已更新 Replay 上下文，请确保传入 UIAbilityContext 以启用屏幕帧
    try {
      // 调用内部 API 进行日志输出
      replayInfo('ReplayIntegration', '已更新 Replay 上下文，请确保传入 UIAbilityContext 以启用屏幕帧');
    } catch (_) {}
  }

  public async captureReplay(): Promise<string | undefined> {
    if (!this.context) return undefined;
    await captureReplayOnError(this.context);
    return getReplayId();
  }

  public shutdown(): void {
    stopReplay();
  }
}


