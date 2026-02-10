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

// 依赖 @pura/harmony-utils（V1.3.8）：https://ohpm.openharmony.cn/#/cn/detail/@pura%2Fharmony-utils
// 采用静态导入，便于 IDE/编译器类型推断；同时对缺失字段做健壮性判断
import * as harmonyUtils from '@pura/harmony-utils';

type Primitive = string | number | boolean | null | undefined;
type LogArg = Primitive | Record<string, Primitive>;

function toStrings(args: LogArg[]): string[] {
  const list: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (typeof a === 'string') list.push(a);
    else if (a === null || a === undefined) list.push(String(a));
    else if (typeof a === 'number' || typeof a === 'boolean') list.push(String(a));
    else list.push(JSON.stringify(a));
  }
  return list;
}

interface HarmonyLoggerLike {
  info: (...args: LogArg[]) => void;
  warn: (...args: LogArg[]) => void;
  error: (...args: LogArg[]) => void;
  debug: (...args: LogArg[]) => void;
}

export const HarmonyLogger: HarmonyLoggerLike = {
  info: (...args: LogArg[]): void => {
    const texts = toStrings(args);
    console.info('[SentryOHOS]', ...texts);
  },
  warn: (...args: LogArg[]): void => {
    const texts = toStrings(args);
    console.warn('[SentryOHOS]', ...texts);
  },
  error: (...args: LogArg[]): void => {
    const texts = toStrings(args);
    console.error('[SentryOHOS]', ...texts);
  },
  debug: (...args: LogArg[]): void => {
    const texts = toStrings(args);
    console.debug('[SentryOHOS]', ...texts);
  },
};

export function getDeviceInfoSafe(): Record<string, Primitive> {
  // 移除对外部库的依赖，返回空对象以保证类型安全
  return {};
}

export function getAppInfoSafe(): Record<string, Primitive> {
  // 移除对外部库的依赖，返回空对象以保证类型安全
  return {};
}

export function nowMs(): number {
  // 优先高精度时间；ArkTS 环境下避免使用 globalThis
  return Date.now();
}


