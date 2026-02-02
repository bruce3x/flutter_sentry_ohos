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

import { SentryOptions } from './SentryOptions';
import { ITransport } from './Transport';
import { Session, SessionStatus } from './Session';
import { ClientReport } from './ClientReport';
import { SentryBaseEvent, SentryEvent, SentryTransaction } from './SentryEvent';
import { UserFeedback, UserFeedbackPayload } from './UserFeedback';
import { FileEnvelopeCache } from './Cache';
import { Breadcrumb } from './Breadcrumb';
import { User } from './User';
import { Scope } from './Scope';
import { SentryException } from './SentryException';
import { HttpTransport } from './HttpTransport';
import type { AttachmentSpec } from './HttpTransport';
import { SentryLevel } from './SentryLevel';
import { Sentry } from './Sentry';
import { IScopes } from './Scopes';
import { collectDeviceContext } from '../core/Context';
import { sentryDebug } from './SentryLogger';

type Primitive = string | number | boolean | null | undefined;

export class Hub implements IScopes {
  transport: HttpTransport | null = null;
  scope: Scope;
  session: Session | null = null;
  clientReport: ClientReport | null = null;
  options: SentryOptions;
  cache: FileEnvelopeCache | null = null;
  private _lastEventId: string | null = null;
  private static _instance: Hub | null = null;

  constructor(options: SentryOptions) {
    this.options = options;
    this.scope = new Scope();
  }

  getOptions(): SentryOptions {
    return this.options;
  }

  initScope(): void {
    this.scope = new Scope(); // 内部 user 为默认构造
  }
  initSession(): void {
    const session = new Session(this.generateSessionId());
    session.release = this.options.release || undefined;
    session.init = true;
    session.status = session.status || SessionStatus.Ok;
    session.errors = 0;
    session.started = new Date().toISOString();
    session.release = this.options.release;
    session.environment = this.options.environment || undefined;
    this.session = session;
  }
  initClientReport(): void {
    const report = new ClientReport();
    report.timestamp = new Date().toISOString();
    report.discardedEvents = [];
    this.clientReport = report;
  }

  setTransport(transport: HttpTransport): void { this.transport = transport; }

  setCache(cache: FileEnvelopeCache | null): void { this.cache = cache; }

  applyEventProcessors(event: SentryBaseEvent): SentryBaseEvent {
    if (event.eventProcessors) {
      for (const processor of event.eventProcessors) {
        try {
          const res = processor(event);
          if (res) event = res;
        } catch (e) {
          if (this.options.debug) console.error('[Sentry] [Hub] eventProcessor failed', e);
        }
      }
    }
    return event;
  }

  public async captureMessage(message: string): Promise<void> {
    let event = new SentryEvent(message);
    this.applyScopeData(event);
    this.enforceOhosContexts(event);
    event.breadcrumbs = this.scope.breadcrumbs.slice();
    if (this.scope.level) event.level = this.scope.level;
    if (this.scope.fingerprint) event.fingerprint = this.scope.fingerprint.slice();
    event = this.applyEventProcessors(event as SentryBaseEvent) as SentryEvent;
    // errorsSampleRate 采样与 beforeSend 回调
    if (!this.sampleErrorEvent(event)) {
      if (this.clientReport) this.clientReport.addDiscardedEvent('sample_rate', 'error', 1);
      return;
    }
    const maybe = this.runBeforeSend(event);
    if (maybe === null) {
      if (this.clientReport) this.clientReport.addDiscardedEvent('before_send', 'event', 1);
      return;
    }
    event = maybe;
    if (!this.transport) {
      if (this.cache) {
        this.cache.store(event);
      }
      return;
    }
    await this.transport.send(event);
    this._lastEventId = event.event_id;
  }

  public async captureException(error: Error): Promise<void> {
    let event = new SentryEvent(error.message);
    this.applyScopeData(event);
    this.enforceOhosContexts(event);
    event.breadcrumbs = this.scope.breadcrumbs.slice();
    if (this.scope.level) event.level = this.scope.level;
    if (this.scope.fingerprint) event.fingerprint = this.scope.fingerprint.slice();
    let exp = new SentryException();
    exp.type = error.name;
    exp.value = error.message;
    event.exceptions = [exp];
    event = this.applyEventProcessors(event as SentryBaseEvent) as SentryEvent;
    // errorsSampleRate 与 beforeSend
    if (!this.sampleErrorEvent(event)) {
      if (this.clientReport) this.clientReport.addDiscardedEvent('sample_rate', 'error', 1);
      return;
    }
    const maybe = this.runBeforeSend(event);
    if (maybe === null) {
      if (this.clientReport) this.clientReport.addDiscardedEvent('before_send', 'event', 1);
      return;
    }
    event = maybe;
    if (!this.transport) {
      if (this.cache) {
        this.cache.store(event);
      }
      return;
    }
    await this.transport.send(event);
    this._lastEventId = event.event_id;
    if (this.session) {
      this.session.incrementErrors();
      if (this.session.errors > 0) {
        // 会话错误计数增加后的日志，便于分析异常追踪和会话状态
        sentryDebug('Hub', `Session errors incremented: count=${this.session.errors}, sessionId=${this.session.sessionId || 'unknown'}, status=${this.session.status || 'unknown'}`);
      }
    }
  }

  public async captureEvent(event: SentryEvent): Promise<void> {
    this.applyScopeData(event);
    this.enforceOhosContexts(event);
    event.breadcrumbs = this.scope.breadcrumbs.slice();
    if (this.scope.level && !event.level) event.level = this.scope.level;
    if (this.scope.fingerprint && !event.fingerprint) event.fingerprint = this.scope.fingerprint.slice();
    event = this.applyEventProcessors(event as SentryBaseEvent) as SentryEvent;
    if (!this.sampleErrorEvent(event)) {
      if (this.clientReport) this.clientReport.addDiscardedEvent('sample_rate', 'error', 1);
      return;
    }
    const maybe = this.runBeforeSend(event);
    if (maybe === null) {
      if (this.clientReport) this.clientReport.addDiscardedEvent('before_send', 'event', 1);
      return;
    }
    event = maybe;
    if (!this.transport) {
      if (this.cache) {
        this.cache.store(event);
      }
      return;
    }
    await this.transport.send(event);
    this._lastEventId = event.event_id;
    if (this.session) {
      // ANR 等异常可计为错误
      this.session.incrementErrors();
    }
  }

  // 与 Android 对齐：按相同采样/beforeSend 规则，使用同一 envelope 发送事件+附件
  public async captureEventWithAttachments(event: SentryEvent, attachments: Array<AttachmentSpec>): Promise<void> {
    this.applyScopeData(event);
    this.enforceOhosContexts(event);
    event.breadcrumbs = this.scope.breadcrumbs.slice();
    if (this.scope.level && !event.level) event.level = this.scope.level;
    if (this.scope.fingerprint && !event.fingerprint) event.fingerprint = this.scope.fingerprint.slice();
    event = this.applyEventProcessors(event as SentryBaseEvent) as SentryEvent;
    if (!this.sampleErrorEvent(event)) {
      if (this.clientReport) this.clientReport.addDiscardedEvent('sample_rate', 'error', 1);
      return;
    }
    const maybe = this.runBeforeSend(event);
    if (maybe === null) {
      if (this.clientReport) this.clientReport.addDiscardedEvent('before_send', 'event', 1);
      return;
    }
    event = maybe;
    if (!this.transport) {
      if (this.cache) this.cache.store(event);
      return;
    }
    try {
      const ok = await (this.transport as HttpTransport).sendEventWithAttachments(event, attachments);
      if (ok) this._lastEventId = event.event_id;
    } catch (_) {
      // 回退：单发事件
      try { await this.transport.send(event); this._lastEventId = event.event_id; } catch (_) {}
    }
  }

  public async captureTransaction(event: SentryTransaction): Promise<void> {
    this.applyScopeData(event);
    event.breadcrumbs = this.scope.breadcrumbs.slice();
    const processed = this.applyEventProcessors(event as SentryBaseEvent) as SentryTransaction;
    // tracesSampler / tracesSampleRate
    if (!this.sampleTransaction(processed)) {
      if (this.clientReport) this.clientReport.addDiscardedEvent('sample_rate', 'transaction', 1);
      return;
    }
    if (!this.transport) {
      if (this.cache) this.cache.store(processed);
      return;
    }
    await this.transport.send(processed);
    // 事务不计入 session 错误
  }

  public async captureUserFeedback(feedback: UserFeedback): Promise<void> {
    if (!this.transport) return;
    let eventId = feedback.eventId;
    if (!eventId) {
      const lastId = this._lastEventId;
      if (!lastId) return;
      eventId = lastId;
    }
    const payload: UserFeedbackPayload = { event_id: eventId };
    if (feedback.name) payload.name = feedback.name;
    if (feedback.email) payload.email = feedback.email;
    if (feedback.comments) payload.comments = feedback.comments;
    await this.transport.sendUserFeedback(payload);
  }

  private applyScopeData(event: SentryBaseEvent): void {
    // tags
    if (this.scope && this.scope.tags) {
      const keys = Object.keys(this.scope.tags);
      for (let i = 0; i < keys.length; i++) {
        const k = keys[i];
        const v = this.scope.tags[k];
        if (typeof v === 'string') {
          event.tags[k] = v;
        }
      }
    }
    // contexts
    if (this.scope && this.scope.contexts) {
      const keys = Object.keys(this.scope.contexts);
      for (let i = 0; i < keys.length; i++) {
        const k = keys[i];
        const v = this.scope.contexts[k];
        if (v !== null && v !== undefined) {
          event.contexts[k] = v as Object;
        }
      }
    }
    // extras
    if (this.scope && this.scope.extra) {
      const keys = Object.keys(this.scope.extra);
      for (let i = 0; i < keys.length; i++) {
        const k = keys[i];
        const v = this.scope.extra[k];
        if (v !== null && v !== undefined) {
          event.extras[k] = String(v);
        }
      }
    }
    // user（若宿主未设置有效用户，则使用默认用户）
    if (this.scope && this.scope.user) {
      const u = this.scope.user as User;
      const hasCustom = !!(u && (u.id || u.username || u.email || u.ip_address));
      if (hasCustom) {
        event.user = u;
      } else {
        const def = new User();
        def.username = 'default_user';
        event.user = def;
      }
    }
    // overwrite level/transaction/fingerprint if set on scope
    if (this.scope.level) event.level = this.scope.level;
    if (this.scope.fingerprint) event.fingerprint = this.scope.fingerprint.slice();
  }

  // 确保事件在发送前携带正确的 OHOS 上下文，避免被上层 Flutter/Android 默认上下文覆盖
  private enforceOhosContexts(event: SentryBaseEvent): void {
    // 强制设置 tags 以便筛选
    try {
      if (!event.tags) event.tags = {};
      event.tags['event.origin'] = 'openharmony';
      event.tags['event.environment'] = 'arkts';
      event.tags['os.name'] = 'OpenHarmony';
    } catch (_) {}

    try {
      // 使用 scope 中的 OHOS contexts 覆盖事件中的 os/device
      if (!event.contexts) event.contexts = {} as Record<string, Object>;
      const scopeOs = this.scope && this.scope.contexts ? this.scope.contexts['os'] : undefined;
      const scopeDevice = this.scope && this.scope.contexts ? this.scope.contexts['device'] : undefined;
      if (scopeOs !== undefined && scopeOs !== null) {
        event.contexts['os'] = scopeOs as Object;
      } else {
        // 至少确保 name 为 OpenHarmony
        const osCtx: Record<string, Object> = {};
        osCtx['name'] = 'OpenHarmony' as Object;
        event.contexts['os'] = osCtx as Object;
      }
      if (scopeDevice !== undefined && scopeDevice !== null) {
        event.contexts['device'] = scopeDevice as Object;
      } else {
        // 如果没有 scope device，则收集完整的设备上下文
        const deviceCtx: Record<string, Primitive> = collectDeviceContext();
        if (deviceCtx) {
          event.contexts['device'] = deviceCtx as Object;
        }
      }
    } catch (_) {}
  }

  public async flush(timeoutMs: number = 2000): Promise<boolean> {
    if (this.transport) {
      return await this.transport.flush(timeoutMs);
    } else if (this.cache && this.transport) {
      return false;
    }
    return true;
  }

  setTag(key: string, value: string): void {
    this.scope.setTag(key, value);
  }

  removeTag(key: string): void {
    this.scope.removeTag(key);
  }

  setExtra(key: string, value: Object): void {
    this.scope.setExtra(key, value);
  }

  removeExtra(key: string): void {
    this.scope.removeExtra(key);
  }

  setUser(user: User): void {
    // 设置全局单例 user
    this.scope.setUser(user);
  }

  setLevel(level: SentryLevel | undefined): void {
    this.scope.setLevel(level);
  }

  setTransaction(name: string | undefined): void {
    this.scope.setTransaction(name);
  }

  setFingerprint(list: Array<string> | undefined): void {
    this.scope.setFingerprint(list);
  }

  addBreadcrumb(breadcrumb: Breadcrumb): void {
    // beforeBreadcrumb 回调（允许丢弃/修改）
    const cb = this.options.beforeBreadcrumb;
    if (cb) {
      try {
        const res = cb(breadcrumb);
        if (res === null) return;
        this.scope.addBreadcrumb(res);
        return;
      } catch (e) {
        // 忽略回调异常，照常添加
      }
    }
    this.scope.addBreadcrumb(breadcrumb);
  }

  clearBreadcrumbs(): void {
    this.scope.clearBreadcrumbs();
  }

  setContext(key: string, value: Object): void {
    this.scope.setContext(key, value);
  }

  removeContext(key: string): void {
    this.scope.removeContext(key);
  }

  clone(): Hub {
    const newHub = new Hub(this.options);
    newHub.scope = this.scope.clone();
    newHub.transport = this.transport; // Transport 通常共享实例
    newHub.session = this.session;     // Session 可以共享
    newHub.clientReport = this.clientReport; // ClientReport 可以共享
    newHub.cache = this.cache;         // 缓存共享
    return newHub;
  }

  getLastEventId(): string | null {
    return this._lastEventId;
  }

  // Session controls similar to Android
  startSession(): void {
    // end current session if any
    try { this.endSession(); } catch (_) {}
    const session = new Session(this.generateSessionId());
    session.init = true;
    session.status = SessionStatus.Ok;
    session.errors = 0;
    session.started = new Date().toISOString();
    session.release = this.options.release || undefined;
    session.environment = this.options.environment || undefined;
    this.session = session;
  }

  endSession(): void {
    if (this.session) {
      this.session.closeSession();
      this.session.updateStatus(SessionStatus.Exited);
    }
  }

  // Parity shim with Android's IScopes.isNoOp()
  isNoOp(): boolean { return false; }

  // Parity shim with Android's IScopes.getScope()
  getScope(): Scope { return this.scope; }
  getIsolationScope(): Scope { return this.scope; }
  getGlobalScope(): Scope { return this.scope; }

  // Parity shim with Android's IScopes.forkedScopes(String)
  forkedScopes(_creator: string): Hub {
    return this.clone();
  }
  forkedCurrentScope(_creator: string): Hub { return this.clone(); }
  forkedRootScopes(_creator: string): Hub { return this.clone(); }
  getParentScopes(): Hub | null { return null; }
  isAncestorOf(_other: IScopes | null): boolean { return false; }

  private generateSessionId(): string {
    // simple id generator; replace with util.generateRandomUUID if available
    return Math.random().toString(36).substring(2, 10) + Date.now().toString(36);
  }

  private sampleErrorEvent(event: SentryEvent): boolean {
    // 若配置 errorsSampleRate，按比例采样；默认全量
    const rate = this.options.errorsSampleRate;
    if (typeof rate === 'number') {
      if (rate <= 0) return false;
      if (rate >= 1) return true;
      return Math.random() < rate;
    }
    return true;
  }

  private sampleTransaction(tx: SentryTransaction): boolean {
    // 优先 tracesSampler(ctx)，否则 tracesSampleRate
    const sampler = this.options.tracesSampler;
    if (sampler) {
      try {
        const rate = sampler({ transaction: { name: tx.transaction } });
        if (typeof rate === 'number') {
          if (rate <= 0) return false;
          if (rate >= 1) return true;
          return Math.random() < rate;
        }
      } catch (_) {}
    }
    const sr = this.options.tracesSampleRate;
    if (typeof sr === 'number') {
      if (sr <= 0) return false;
      if (sr >= 1) return true;
      return Math.random() < sr;
    }
    return true;
  }

  private runBeforeSend(event: SentryEvent): SentryEvent | null {
    const cb = this.options.beforeSend;
    if (!cb) return event;
    try {
      const res = cb(event);
      return res;
    } catch (_) {
      return event;
    }
  }
}
