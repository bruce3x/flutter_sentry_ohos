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

export enum SessionStatus {
  Ok = "ok",
  Exited = "exited",
  Crashed = "crashed",
  Abnormal = "abnormal"
}

export class Session {
  sessionId: string;
  distinctId?: string;
  started: string;
  status: SessionStatus = SessionStatus.Ok;
  errors: number = 0;
  duration?: number;
  init: boolean = true;
  release?: string;
  environment?: string;
  ipAddress?: string;
  userAgent?: string;
  attributes?: Record<string, Object>;

  constructor(sessionId: string) {
    this.sessionId = sessionId;
    this.started = new Date().toISOString();
  }

  updateStatus(newStatus: SessionStatus): void {
    this.status = newStatus;
  }

  incrementErrors(): void {
    this.errors += 1;
  }

  closeSession(): void {
    const startTime = new Date(this.started).getTime();
    const now = Date.now();
    this.duration = (now - startTime) / 1000; // 秒
    this.init = false;
  }

  clone(): Session {
    const newSession = new Session(this.sessionId);
    newSession.distinctId = this.distinctId;
    newSession.started = this.started;
    newSession.status = this.status;
    newSession.errors = this.errors;
    newSession.duration = this.duration;
    newSession.init = this.init;
    newSession.release = this.release;
    newSession.environment = this.environment;
    newSession.ipAddress = this.ipAddress;
    newSession.userAgent = this.userAgent;
    newSession.attributes = this.attributes;
    return newSession;
  }
}
