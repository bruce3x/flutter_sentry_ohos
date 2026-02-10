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

import { HttpTransport } from '../sentry/HttpTransport';
import { SentryEvent } from '../sentry/SentryEvent';
import { SentryOptions } from '../sentry/SentryOptions';
import { ReplayPayload } from './types';

export class EventTransport {
  public async sendReplay(serverUrl: string, payload: ReplayPayload): Promise<boolean> {
    const options = new SentryOptions();
    options.dsn = serverUrl;

    const transport = new HttpTransport(options);
    const event = new SentryEvent('replay');
    event.contexts['replay'] = (payload as Object);
    return await transport.send(event);
  }
}
