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

export interface DiscardedEvent {
  reason: string;
  category: string;
  quantity: number;
}

export class ClientReport {
  timestamp: string;
  discardedEvents: Array<DiscardedEvent>;

  constructor() {
    this.timestamp = new Date().toISOString();
    this.discardedEvents = [];
  }

  addDiscardedEvent(reason: string, category: string, quantity: number = 1): void {
    let existing = this.discardedEvents.find(e => e.reason === reason && e.category === category);
    if (existing) existing.quantity += quantity;
    else this.discardedEvents.push({ reason, category, quantity });
  }

  hasItems(): boolean { return this.discardedEvents.length > 0; }

  buildPayload(): ClientReportPayload {
    const items: Array<DiscardedEvent> = [];
    for (let i = 0; i < this.discardedEvents.length; i++) items.push(this.discardedEvents[i]);
    const payload: ClientReportPayload = { timestamp: this.timestamp, discarded_events: items };
    return payload;
  }

  reset(): void {
    this.timestamp = new Date().toISOString();
    this.discardedEvents = [];
  }
}

export interface ClientReportPayload { timestamp: string; discarded_events: Array<DiscardedEvent> }
