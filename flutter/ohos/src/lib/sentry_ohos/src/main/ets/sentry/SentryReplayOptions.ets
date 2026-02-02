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

export type ReplayEventListener = (eventType: string, payload?: object) => void;

export class SentryReplayOptions {
  autoStart: boolean;
  sessionSampleRate: number;
  errorSampleRate: number;
  attachScreenshots: boolean;
  customEndpoint?: string;
  networkBreadcrumbs: boolean;
  domCapture: boolean;
  replayEventListener?: ReplayEventListener;

  constructor(
    autoStart: boolean = true,
    sessionSampleRate: number = 1.0,
    errorSampleRate: number = 1.0,
    attachScreenshots: boolean = false,
    customEndpoint?: string,
    networkBreadcrumbs: boolean = true,
    domCapture: boolean = false,
    replayEventListener?: ReplayEventListener
  ) {
    this.autoStart = autoStart;
    this.sessionSampleRate = sessionSampleRate;
    this.errorSampleRate = errorSampleRate;
    this.attachScreenshots = attachScreenshots;
    this.customEndpoint = customEndpoint;
    this.networkBreadcrumbs = networkBreadcrumbs;
    this.domCapture = domCapture;
    this.replayEventListener = replayEventListener;
  }
}
