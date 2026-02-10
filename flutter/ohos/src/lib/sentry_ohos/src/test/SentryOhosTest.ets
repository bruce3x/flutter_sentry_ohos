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
import { SentryOhos } from '../main/ets/core/SentryOhos';
import { SentryOhosOptions } from '../main/ets/core/SentryOhosOptions';
import { SentryLevel } from '../main/ets/sentry/SentryLevel';

export default function sentryOhosTest() {
  describe('SentryOhosTest', () => {
    let sentryOhos: SentryOhos;
    let options: SentryOhosOptions;

    beforeAll(() => {
      // 初始化测试环境
    });

    beforeEach(() => {
      options = new SentryOhosOptions();
      options.dsn = 'https://test@sentry.io/123';
      options.debug = true;
      options.environment = 'test';
      options.release = '1.0.0';
      sentryOhos = new SentryOhos();
    });

    afterEach(() => {
      // 清理测试环境
    });

    afterAll(() => {
      // 清理所有资源
    });

    it('should initialize with valid options', 0, () => {
      expect(sentryOhos).assertInstanceOf(SentryOhos);
      expect(options.dsn).assertEqual('https://test@sentry.io/123');
      expect(options.debug).assertTrue();
      expect(options.environment).assertEqual('test');
      expect(options.release).assertEqual('1.0.0');
    });

    it('should set debug level correctly', 0, () => {
      options.debug = true;
      expect(options.debug).assertTrue();

      options.debug = false;
      expect(options.debug).assertFalse();
    });

    it('should set environment correctly', 0, () => {
      options.environment = 'production';
      expect(options.environment).assertEqual('production');

      options.environment = 'development';
      expect(options.environment).assertEqual('development');
    });

    it('should set release correctly', 0, () => {
      options.release = '2.0.0';
      expect(options.release).assertEqual('2.0.0');
    });

    it('should set sample rates correctly', 0, () => {
      options.tracesSampleRate = 0.5;
      options.errorsSampleRate = 0.8;

      expect(options.tracesSampleRate).assertEqual(0.5);
      expect(options.errorsSampleRate).assertEqual(0.8);
    });

    it('should set ANR configuration correctly', 0, () => {
      options.enableAnr = true;
      options.anrThresholdMs = 5000;
      options.anrReportInDebug = true;

      expect(options.enableAnr).assertTrue();
      expect(options.anrThresholdMs).assertEqual(5000);
      expect(options.anrReportInDebug).assertTrue();
    });

    it('should set HTTP configuration correctly', 0, () => {
      options.httpEndpoint = 'https://custom.sentry.io/api/123';
      options.httpConnectTimeoutMs = 10000;
      options.httpReadTimeoutMs = 15000;
      options.httpMaxRetries = 3;

      expect(options.httpEndpoint).assertEqual('https://custom.sentry.io/api/123');
      expect(options.httpConnectTimeoutMs).assertEqual(10000);
      expect(options.httpReadTimeoutMs).assertEqual(15000);
      expect(options.httpMaxRetries).assertEqual(3);
    });

    it('should set view hierarchy configuration correctly', 0, () => {
      options.enableViewHierarchy = true;
      options.includeViewText = true;
      options.maxViewNodes = 100;
      options.maxViewDepth = 10;

      expect(options.enableViewHierarchy).assertTrue();
      expect(options.includeViewText).assertTrue();
      expect(options.maxViewNodes).assertEqual(100);
      expect(options.maxViewDepth).assertEqual(10);
    });

    it('should set replay configuration correctly', 0, () => {
      options.enableReplay = true;
      options.replayServerUrl = 'https://replay.sentry.io';

      expect(options.enableReplay).assertTrue();
      expect(options.replayServerUrl).assertEqual('https://replay.sentry.io');
    });

    it('should set breadcrumb configuration correctly', 0, () => {
      options.enableUiBreadcrumbs = true;
      options.enableAppLifecycleBreadcrumbs = true;
      options.freezeBreadcrumbsMaxKeys = 50;

      expect(options.enableUiBreadcrumbs).assertTrue();
      expect(options.enableAppLifecycleBreadcrumbs).assertTrue();
      expect(options.freezeBreadcrumbsMaxKeys).assertEqual(50);
    });

    it('should set attachment configuration correctly', 0, () => {
      options.maxAttachmentBytes = 1024 * 1024; // 1MB

      expect(options.maxAttachmentBytes).assertEqual(1024 * 1024);
    });

    it('should set sampling configuration correctly', 0, () => {
      options.crashSampleRate = 0.1;
      options.freezeSampleRate = 0.2;

      expect(options.crashSampleRate).assertEqual(0.1);
      expect(options.freezeSampleRate).assertEqual(0.2);
    });
  });
}
