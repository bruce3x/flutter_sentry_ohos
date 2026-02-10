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

export class ScreenshotRecorderConfig {
  recordingWidth: number;
  recordingHeight: number;
  scaleFactorX: number;
  scaleFactorY: number;
  frameRate: number;
  bitRate: number;

  constructor(
    recordingWidth: number,
    recordingHeight: number,
    scaleFactorX: number,
    scaleFactorY: number,
    frameRate: number,
    bitRate: number
  ) {
    this.recordingWidth = Math.max(1, Math.floor(recordingWidth));
    this.recordingHeight = Math.max(1, Math.floor(recordingHeight));
    this.scaleFactorX = scaleFactorX > 0 ? scaleFactorX : 1.0;
    this.scaleFactorY = scaleFactorY > 0 ? scaleFactorY : 1.0;
    this.frameRate = Math.max(1, Math.floor(frameRate));
    // OHOS 当前未使用视频编码比特率（采用定时截图方案），保留字段以保持兼容
    this.bitRate = Math.max(0, Math.floor(bitRate));
  }
}
