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

import { HarmonyLogger } from './HarmonyUtilsAdapter';

type ErrorHandler = (error: Error) => void;

let installed = false;
let customHandler: ErrorHandler | null = null;

// 可选全局钩子（ArkTS 环境若不支持则为 undefined）
// 使用具名类型避免 any/unknown
type GlobalOnError = (message: string | object, source?: string, lineno?: number, colno?: number, error?: Error) => boolean | void;
interface UnhandledRejectionEvt { reason?: Error | string }
type GlobalOnUnhandledRejection = (event: UnhandledRejectionEvt) => void;

declare let onerror: GlobalOnError | undefined;
declare let onunhandledrejection: GlobalOnUnhandledRejection | undefined;

export function installGlobalErrorHandler(handler: ErrorHandler): void {
  if (installed) return;
  installed = true;
  customHandler = handler;

  // ArkTS 全局异常兜底：onerror / onunhandledrejection 可能存在于全局对象
  try {
    const hasOnError = typeof onerror !== 'undefined';
    const originalOnError: GlobalOnError | undefined = hasOnError ? onerror : undefined;
    if (hasOnError){
      onerror = (msg: string | object, source?: string, lineno?: number, colno?: number, error?: Error) => {
        try {
          const err = error || new Error(typeof msg === 'string' ? msg : JSON.stringify(msg));
          customHandler && customHandler(err);
        } catch (err) {
          HarmonyLogger.error('onerror handler failed', err);
        }
        if (typeof originalOnError === 'function') {
          try { return originalOnError(msg, source, lineno, colno, error); } catch (_) {}
        }
        return false;
      };
    }

    const hasOnUnhandled = typeof onunhandledrejection !== 'undefined';
    const originalOnUnhandledRejection: GlobalOnUnhandledRejection | undefined = hasOnUnhandled ? onunhandledrejection : undefined;
    if (hasOnUnhandled) {
      onunhandledrejection = (event: UnhandledRejectionEvt) => {
        try {
          const reason = event?.reason;
          if (reason instanceof Error) customHandler && customHandler(reason);
          else customHandler && customHandler(new Error(typeof reason === 'string' ? reason : 'unhandled rejection'));
        } catch (err) {
          HarmonyLogger.error('onunhandledrejection handler failed', err);
        }
        if (typeof originalOnUnhandledRejection === 'function') {
          try { return originalOnUnhandledRejection(event); } catch (_) {}
        }
      };
    }
  } catch (e) {
    HarmonyLogger.warn('Global error hooks not available', e);
  }
}


