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

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { SentryOhosOptions } from '../main/ets/core/SentryOhosOptions';
import { SentryLevel } from '../main/ets/sentry/SentryLevel';

export default function sentryOhosOptionsTest() {
  describe('SentryOhosOptionsTest', () => {
    let options: SentryOhosOptions;

    beforeAll(() => {
      // 初始化测试环境
    });

    beforeEach(() => {
      options = new SentryOhosOptions();
    });

    afterEach(() => {
      // 清理测试环境
    });

    afterAll(() => {
      // 清理所有资源
    });

    it('should create options with default values', 0, () => {
      expect(options).assertInstanceOf(SentryOhosOptions);
      expect(options.debug).assertFalse();
      expect(options.environment).assertUndefined();
      expect(options.release).assertUndefined();
    });

    it('should set and get DSN correctly', 0, () => {
      const dsn = 'https://test@sentry.io/123';
      options.dsn = dsn;
      expect(options.dsn).assertEqual(dsn);
    });

    it('should set and get debug flag correctly', 0, () => {
      options.debug = true;
      expect(options.debug).assertTrue();

      options.debug = false;
      expect(options.debug).assertFalse();
    });

    it('should set and get environment correctly', 0, () => {
      const environment = 'production';
      options.environment = environment;
      expect(options.environment).assertEqual(environment);
    });

    it('should set and get release correctly', 0, () => {
      const release = '1.0.0';
      options.release = release;
      expect(options.release).assertEqual(release);
    });

    it('should set and get sample rates correctly', 0, () => {
      options.tracesSampleRate = 0.5;
      options.errorsSampleRate = 0.8;

      expect(options.tracesSampleRate).assertEqual(0.5);
      expect(options.errorsSampleRate).assertEqual(0.8);
    });

    it('should set and get ANR configuration correctly', 0, () => {
      options.enableAnr = true;
      options.anrThresholdMs = 5000;
      options.anrTickerIntervalMs = 100;
      options.anrReportInDebug = true;

      expect(options.enableAnr).assertTrue();
      expect(options.anrThresholdMs).assertEqual(5000);
      expect(options.anrTickerIntervalMs).assertEqual(100);
      expect(options.anrReportInDebug).assertTrue();
    });

    it('should set and get HTTP configuration correctly', 0, () => {
      options.httpEndpoint = 'https://custom.sentry.io/api/123';
      options.httpConnectTimeoutMs = 10000;
      options.httpReadTimeoutMs = 15000;
      options.httpMaxRetries = 3;
      options.httpRetryBaseDelayMs = 1000;

      expect(options.httpEndpoint).assertEqual('https://custom.sentry.io/api/123');
      expect(options.httpConnectTimeoutMs).assertEqual(10000);
      expect(options.httpReadTimeoutMs).assertEqual(15000);
      expect(options.httpMaxRetries).assertEqual(3);
      expect(options.httpRetryBaseDelayMs).assertEqual(1000);
    });

    it('should set and get view hierarchy configuration correctly', 0, () => {
      options.enableViewHierarchy = true;
      options.includeViewText = true;
      options.maxViewNodes = 100;
      options.maxViewDepth = 10;

      expect(options.enableViewHierarchy).assertTrue();
      expect(options.includeViewText).assertTrue();
      expect(options.maxViewNodes).assertEqual(100);
      expect(options.maxViewDepth).assertEqual(10);
    });

    it('should set and get replay configuration correctly', 0, () => {
      options.enableReplay = true;
      options.replayServerUrl = 'https://replay.sentry.io';

      expect(options.enableReplay).assertTrue();
      expect(options.replayServerUrl).assertEqual('https://replay.sentry.io');
    });

    it('should set and get breadcrumb configuration correctly', 0, () => {
      options.enableUiBreadcrumbs = true;
      options.enableAppLifecycleBreadcrumbs = true;
      options.freezeBreadcrumbsMaxKeys = 50;

      expect(options.enableUiBreadcrumbs).assertTrue();
      expect(options.enableAppLifecycleBreadcrumbs).assertTrue();
      expect(options.freezeBreadcrumbsMaxKeys).assertEqual(50);
    });

    it('should set and get attachment configuration correctly', 0, () => {
      options.maxAttachmentBytes = 1024 * 1024; // 1MB

      expect(options.maxAttachmentBytes).assertEqual(1024 * 1024);
    });

    it('should set and get sampling configuration correctly', 0, () => {
      options.crashSampleRate = 0.1;
      options.freezeSampleRate = 0.2;

      expect(options.crashSampleRate).assertEqual(0.1);
      expect(options.freezeSampleRate).assertEqual(0.2);
    });

    it('should set and get transaction configuration correctly', 0, () => {
      options.autoCommitTransactions = true;
      options.commitTimeoutMs = 5000;

      expect(options.autoCommitTransactions).assertTrue();
      expect(options.commitTimeoutMs).assertEqual(5000);
    });

    it('should set and get HiAppEvent configuration correctly', 0, () => {
      options.enableHiAppWatcher = true;

      expect(options.enableHiAppWatcher).assertTrue();
    });

    it('should set and get user interaction configuration correctly', 0, () => {
      options.enableUserInteractionIntegration = true;

      expect(options.enableUserInteractionIntegration).assertTrue();
    });

    it('should set and get profiles configuration correctly', 0, () => {
      options.profilesSampleRate = 0.3;

      expect(options.profilesSampleRate).assertEqual(0.3);
    });
  });
}
