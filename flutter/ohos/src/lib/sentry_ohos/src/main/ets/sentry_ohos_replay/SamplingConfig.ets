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

export class SamplingConfig {
  public sampleRate: number = 0.1;   // 10%
  public onErrorSampleRate: number = 1.0;   // 100%
  public sessionSampleRate: number = 0.0;   // Android 对齐：全会话采样率
  public frameRate: number = 5; // fps
  public sessionDurationMs: number = 1000 * 60 * 60; // 1h
  public sessionSegmentDurationMs: number = 1000 * 60; // 1m
  public errorReplayDurationMs: number = 1000 * 30; // 30s
  public maxScreenFrames: number = 30; // 限制内存占用：最多保留 30 帧

  constructor(rate: number = 1.0) {
    this.sampleRate = Math.min(Math.max(rate, 0), 1);
  }

  public shouldSampleSession(): boolean {
    return Math.random() < this.sampleRate;
  }

  public shouldSampleOnError(): boolean {
    return Math.random() < this.onErrorSampleRate;
  }

  public shouldSampleFullSession(): boolean {
    return Math.random() < this.sessionSampleRate;
  }
}
