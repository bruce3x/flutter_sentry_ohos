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

import { describe, it, expect } from '@ohos/hypium';
import { SentryOhos } from '../main/ets/core/SentryOhos';

/**
 * 针对 PR #11 新增的原生崩溃摘要解析逻辑的单元测试。
 * 覆盖：
 *   - 典型 APP_CRASH external_log（含 `Reason: Signal:SIGSEGV`）的解析
 *   - Fault thread Info 兜底分支
 *   - reasonLine 超长截断
 *   - faultThreadLine 超长截断（回归：此前 fallback 分支遗漏截断）
 *   - 空内容 / null / 无匹配内容返回 null
 */
export default function sentryCrashSummaryTest() {
  describe('SentryCrashSummaryTest', () => {

    it('returns null for null content', 0, () => {
      const r = SentryOhos.internalExtractCrashSummaryFromLog(null);
      expect(r === null).assertTrue();
    });

    it('returns null for empty content', 0, () => {
      const r = SentryOhos.internalExtractCrashSummaryFromLog('');
      expect(r === null).assertTrue();
    });

    it('returns null when no Reason/FaultThread lines are present', 0, () => {
      const log = 'Random header\nSome other line\nNothing relevant here\n';
      const r = SentryOhos.internalExtractCrashSummaryFromLog(log);
      expect(r === null).assertTrue();
    });

    it('parses typical SIGSEGV Reason line', 0, () => {
      const log = [
        'Device info:ohos',
        'Build info:xxx',
        'Timestamp:2025-01-01 00:00:00',
        'Pid:1234',
        'Uid:20010',
        'Process name:com.example.app',
        'Reason:Signal:SIGSEGV(SEGV_MAPERR)@0xdeadbeef',
        'Fault thread Info:',
        'Tid:1234, Name:main',
      ].join('\n');
      const r = SentryOhos.internalExtractCrashSummaryFromLog(log);
      expect(r !== null).assertTrue();
      const rec = r as Record<string, string>;
      expect(rec['signalType']).assertEqual('SIGSEGV');
      // value 以 'Signal:SIGSEGV' 开头（去掉了 Reason: 前缀）
      expect(rec['value'].indexOf('Signal:SIGSEGV') === 0).assertTrue();
    });

    it('parses SIGABRT', 0, () => {
      const log = 'Reason:Signal:SIGABRT(SI_TKILL)@0x0\n';
      const r = SentryOhos.internalExtractCrashSummaryFromLog(log);
      expect(r !== null).assertTrue();
      const rec = r as Record<string, string>;
      expect(rec['signalType']).assertEqual('SIGABRT');
    });

    it('truncates overlong Reason line to CRASH_SUMMARY_MAX_LENGTH with ellipsis', 0, () => {
      // 构造一个远超 512 字节的 Reason 行
      let payload = '';
      for (let i = 0; i < 1000; i++) payload += 'A';
      const log = 'Reason:' + payload + '\n';
      const r = SentryOhos.internalExtractCrashSummaryFromLog(log);
      expect(r !== null).assertTrue();
      const rec = r as Record<string, string>;
      // 512 字符 + '...'
      expect(rec['value'].length).assertEqual(512 + 3);
      expect(rec['value'].indexOf('...') === 512).assertTrue();
    });

    it('falls back to Fault thread Info when Reason line is missing', 0, () => {
      const log = 'Something else\nFault thread Info:Tid:1234 Name:main sig=11\n';
      const r = SentryOhos.internalExtractCrashSummaryFromLog(log);
      expect(r !== null).assertTrue();
      const rec = r as Record<string, string>;
      expect(rec['value'].indexOf('Fault thread Info:') === 0).assertTrue();
      // 没有 Reason 行 → 没有 signalType
      expect(rec['signalType']).assertEqual('');
    });

    it('truncates overlong Fault thread line (regression: fallback branch)', 0, () => {
      // 回归测试：此前 faultThreadLine 兜底分支未应用 CRASH_SUMMARY_MAX_LENGTH 截断，
      // 修复后应与 reasonLine 分支保持一致截断到 512 + '...'。
      let payload = '';
      for (let i = 0; i < 1000; i++) payload += 'B';
      const log = 'Fault thread Info:' + payload + '\n';
      const r = SentryOhos.internalExtractCrashSummaryFromLog(log);
      expect(r !== null).assertTrue();
      const rec = r as Record<string, string>;
      expect(rec['value'].length).assertEqual(512 + 3);
      expect(rec['value'].endsWith('...')).assertTrue();
    });

    it('prefers Reason line over Fault thread when both exist', 0, () => {
      const log = [
        'Reason:Signal:SIGSEGV(SEGV_MAPERR)@0x1',
        'Fault thread Info:Tid:1',
      ].join('\n');
      const r = SentryOhos.internalExtractCrashSummaryFromLog(log);
      expect(r !== null).assertTrue();
      const rec = r as Record<string, string>;
      expect(rec['value'].indexOf('Signal:SIGSEGV') === 0).assertTrue();
      expect(rec['signalType']).assertEqual('SIGSEGV');
    });
  });
}
