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

const REPLAY_TAG_PREFIX: string = 'REPLAY_TAG ';

type LogLevel = 'info' | 'warn' | 'error' | 'debug' | 'log';

/**
 * 日志开关：设为 true 开启 Replay 模块日志输出，设为 false 关闭日志以提升性能
 * 生产环境建议设为 false
 */
const REPLAY_LOG_ENABLED: boolean = false;

function emit(level: LogLevel, scope: string, message: string): void {
  // 非开发模式下直接返回，不输出日志
  if (!REPLAY_LOG_ENABLED) {
    return;
  }
  try {
    const prefix = REPLAY_TAG_PREFIX + scope + ' ';
    const text = prefix + message;
    switch (level) {
      case 'info':
        console.info(text);
        break;
      case 'warn':
        console.warn(text);
        break;
      case 'error':
        console.error(text);
        break;
      case 'debug':
        console.debug(text);
        break;
      default:
        console.log(text);
        break;
    }
  } catch (_) {}
}

export function replayInfo(scope: string, message: string): void {
  emit('info', scope, message);
}

export function replayWarn(scope: string, message: string): void {
  emit('warn', scope, message);
}

export function replayError(scope: string, message: string): void {
  emit('error', scope, message);
}

export function replayDebug(scope: string, message: string): void {
  emit('debug', scope, message);
}

export function replayLog(scope: string, message: string): void {
  emit('log', scope, message);
}









