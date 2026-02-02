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

import { MethodChannel } from '@ohos/flutter_ohos';
import { getReplayId } from 'sentry_ohos'

/**
 * ReplayBridge: 抽离鸿蒙端与 Flutter 通道的回放录制通讯逻辑，
 * 与 Android 侧的桥接职责一致，仅负责调用通道方法，不包含采样/编码等本地实现。
 */
export class SentryFlutterReplayRecorder {
  private channel: MethodChannel;
  private enabled: boolean = false;

  constructor(channel: MethodChannel) {
    this.channel = channel;
  }

  setEnabled(value: boolean): void {
    this.enabled = value === true;
  }

  startIfHasReplayId(): void {
    if (!this.enabled) return;
    try {
      let rid: string = "";
      try { const id = getReplayId(); rid = typeof id === 'string' ? id : ""; } catch (_) { rid = ""; }
      if (rid.length > 0) {
        const args: Record<string, Object> = { 'replayId': rid as Object };
        try { this.channel.invokeMethod('ReplayRecorder.start', args as Object); } catch (_) {}
      }
    } catch (_) {}
  }

  resume(): void {
    if (!this.enabled) return;
    try { this.channel.invokeMethod('ReplayRecorder.resume', null);
    } catch (_) {}
  }

  pause(): void {
    if (!this.enabled) return;
    try {
      this.channel.invokeMethod('ReplayRecorder.pause', null);
    } catch (_) {}
  }

  stop(): void {
    if (!this.enabled) return;
    try { this.channel.invokeMethod('ReplayRecorder.stop', null);
    } catch (_) {}
  }

  onConfigurationChanged(width: number, height: number, frameRate: number): void {
    if (!this.enabled) return;
    try {
      const args: Record<string, Object> = {
        'width': (width ?? 0) as Object,
        'height': (height ?? 0) as Object,
        'frameRate': (frameRate ?? 2) as Object,
      };
      try { this.channel.invokeMethod('ReplayRecorder.onConfigurationChanged', args as Object);
      } catch (_) {}
    } catch (_) {}
  }
}


