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

import { ReSession } from './types';


// 会话管理
export class SessionManager {
  private currentSession: ReSession | null = null;


  public startSession(): void {
    this.currentSession = {
      id: this.generateSessionId(),
      startTime: Date.now()
    };
  }

  public endSession(): void {
    if (this.currentSession) {
      this.currentSession.endTime = Date.now();
    }
  }

  public getSession(): ReSession | null {
    return this.currentSession;
  }

  private generateSessionId(): string {
    // Generate a 32-character hex string (pseudo-UUID without dashes)
    const chars = '0123456789abcdef';
    let str = '';
    for (let i = 0; i < 32; i++) {
      str += chars.charAt(Math.floor(Math.random() * 16));
    }
    return str;
  }
}
