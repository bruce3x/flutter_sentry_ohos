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

import { ReplayPayload } from './types';
import ReplayEnvelopeSender from './ReplayEnvelopeSender';
import { replayInfo } from './ReplayLogger';

// 上报
export class ReplayTransport {

  /**
   * 上传 ReplayPayload（通过 HttpTransport 复用 Envelope 发送逻辑）
   * @param serverUrl 上报 URL（会作为 dsn 传入 HttpTransport 使用）
   * @param payload ReplayPayload 数据
   * @returns Promise<boolean> 成功返回 true，否则 false
   */
  public async sendReplay(url: string, payload: ReplayPayload): Promise<boolean> {
    const sender = new ReplayEnvelopeSender();
    const ok = await sender.send(url, payload);
    return ok;
  }
}
