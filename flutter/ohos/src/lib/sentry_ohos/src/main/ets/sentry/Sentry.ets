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
import { Hub } from './Hub';
import { SentryEvent, SentryTransaction } from './SentryEvent';
import { UserFeedback } from './UserFeedback';
import { User } from './User'
import { ITransportFactory } from './Transport';
import { HttpTransportFactory } from './HttpTransportFactory';
import { Breadcrumb } from './Breadcrumb';
import { FileEnvelopeCache } from './Cache';
import { HttpTransport } from './HttpTransport';
import { SentryLevel } from './SentryLevel';
import { IScopes, IScopesStorage, NoOpScopes, InMemoryScopesStorage } from './Scopes';

export class Sentry {
  private static _hub: Hub | null = null;
  private static _initialized: boolean = false;
  // globalHubMode/rootScopes analogs for parity with Android
  private static _globalHubMode: boolean = true;
  private static _rootScopes: IScopes | null = null;      // global root scopes
  private static _scopesStorage: IScopesStorage = new InMemoryScopesStorage();

  public static init(options: SentryOptions): void {
    if (Sentry._initialized) {
      console.warn('[Sentry] SDK already initialized');
      return;
    };

    // ensure cache/clientReport passed if desired
    let cache: FileEnvelopeCache | null = null;
    if (options.cacheDirPath) {
      cache = new FileEnvelopeCache(options.cacheDirPath, options.maxCacheItems ?? 30);
    }

    if (!options.transportFactory) {
      // Using default HttpTransportFactory
      options.transportFactory = new HttpTransportFactory(cache, null);
    }

    const hub = new Hub(options);
    hub.setCache(cache);
    hub.initScope();
    hub.initSession();
    hub.initClientReport();
    // 传递 cache 与 clientReport，便于离线落盘与客户端报告回传（对齐 Android）
    const transport = new HttpTransport(options, cache, hub.clientReport);
    hub.setTransport(transport)

    // initialize root scopes and hub
    Sentry._rootScopes = hub;
    Sentry._hub = hub;

    Sentry._initialized = true;
    if (options.debug) {
      console.info('[Sentry] SDK initialized successfully');
    }

    // Run cleanup and flush asynchronously to avoid blocking init
    if (cache) {
      // Use setTimeout to defer heavy IO operations
      const cacheRef = cache;
      const transportRef = transport;
      const debugMode = options.debug;
      setTimeout(() => {
        // Clean up old sent envelopes (>3 days) on SDK startup
        try {
          const cleanupStart = Date.now();
          const cleanedCount = cacheRef.cleanupOldSentEnvelopes();
          // Cleanup completed
        } catch (e) {
          console.error(`[Sentry] Failed to cleanup old sent envelopes: ${e}`);
        }
        // Auto-flush cached events on SDK startup (Android pattern)
        transportRef.flush(80000).then((_: boolean) => {
          if (debugMode) {
            console.info('[Sentry] Startup flush completed');
          }
        }).catch((_: Error) => {
          console.error('[Sentry] Startup flush failed');
        });
      }, 100); // Defer 100ms to allow UI to render first
    }
  }

  public static getHub(): Hub {
    if (!Sentry._hub) throw new Error('[Sentry] SDK not initialized. Call Sentry.init(options) first.');
    return Sentry._hub;
  }

  // Align with Android's Sentry.getCurrentScopes(): return current Hub/Scopes facade
  public static getCurrentScopes(): Hub {
    if (Sentry._globalHubMode) {
      return (Sentry._rootScopes as Hub);
    }
    let scopes = Sentry._scopesStorage.get();
    if (!scopes || scopes.isNoOp()) {
      // Forking scopes: clone with same options
      const root = Sentry._rootScopes as Hub;
      const fork = root.forkedScopes('getCurrentScopes');
      Sentry._scopesStorage.set(fork);
      return fork as Hub;
    }
    return scopes as Hub;
  }

  public static isInitialized(): boolean {
    return Sentry._hub !== null;
  }

  public static getHubIfAvailable(): Hub | null {
    return Sentry._hub;
  }

  public static startSession(): void {
    Sentry.getHub().startSession();
  }

  public static endSession(): void {
    Sentry.getHub().endSession();
  }

  public static async captureMessage(message: string): Promise<void> {
     await Sentry.getHub().captureMessage(message);
  }

  public static async captureException(error: Error): Promise<void> {
     await Sentry.getHub().captureException(error);
  }

  public static async captureEvent(event: SentryEvent): Promise<void> {
     await Sentry.getHub().captureEvent(event);
  }

  public static async captureTransaction(event: SentryTransaction): Promise<void> {
     await Sentry.getHub().captureTransaction(event);
  }

  public static async captureUserFeedback(feedback: UserFeedback): Promise<void> {
     await Sentry.getHub().captureUserFeedback(feedback);
  }

  public static async flush(timeoutMs: number = 2000): Promise<boolean> {
    const hub = Sentry.getHub();
    return await hub.flush(timeoutMs);
  }

  public static setTag(key: string, value: string): void {
    Sentry.getHub().setTag(key, value);
  }

  public static removeTag(key: string): void {
    Sentry.getHub().removeTag(key);
  }

  public static setExtra(key: string, value: Object): void {
    Sentry.getHub().setExtra(key, value);
  }

  public static removeExtra(key: string): void {
    Sentry.getHub().removeExtra(key);
  }

  public static setUser(user: User): void {
    Sentry.getHub().setUser(user);
  }

  // Level / Transaction / Fingerprint controls
  public static setLevel(level: SentryLevel | undefined): void {
    Sentry.getHub().setLevel(level);
  }

  public static setTransaction(name: string | undefined): void {
    Sentry.getHub().setTransaction(name);
  }

  public static setFingerprint(list: Array<string> | undefined): void {
    Sentry.getHub().setFingerprint(list);
  }

  public static getLastEventId(): string | null {
    return Sentry.getHub().getLastEventId();
  }

  public static addBreadcrumb(breadcrumb: Breadcrumb): void {
    Sentry.getHub().addBreadcrumb(breadcrumb);
  }

  public static clearBreadcrumbs(): void {
    Sentry.getHub().clearBreadcrumbs();
  }

  public static setContext(key: string, value: Object): void {
    Sentry.getHub().setContext(key, value);
  }

  public static removeContext(key: string): void {
    Sentry.getHub().removeContext(key);
  }

}
