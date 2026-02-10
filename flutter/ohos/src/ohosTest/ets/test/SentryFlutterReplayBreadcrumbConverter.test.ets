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
import { SentryFlutterReplayBreadcrumbConverter } from '../../main/ets/components/plugin/SentryFlutterReplayBreadcrumbConverter';

export default function sentryFlutterReplayBreadcrumbConverterTest() {
  describe('SentryFlutterReplayBreadcrumbConverterTest', () => {
    let converter: SentryFlutterReplayBreadcrumbConverter;

    beforeAll(() => {
      // 初始化测试环境
    });

    beforeEach(() => {
      converter = new SentryFlutterReplayBreadcrumbConverter();
    });

    afterEach(() => {
      // 清理测试环境
    });

    afterAll(() => {
      // 清理所有测试
    });

    it('should create converter instance', 0, () => {
      expect(converter).assertInstanceOf(SentryFlutterReplayBreadcrumbConverter);
    });

    it('should handle null breadcrumb', 0, () => {
      const result = converter.convert(null);
      expect(result).assertUndefined();
    });

    it('should handle breadcrumb without category', 0, () => {
      const breadcrumb = {
        message: 'Test message',
        level: 'info',
        timestamp: Date.now()
      } as any;

      const result = converter.convert(breadcrumb);
      expect(result).assertUndefined();
    });

    it('should handle sentry.event category', 0, () => {
      const breadcrumb = {
        category: 'sentry.event',
        message: 'Test event',
        level: 'info',
        timestamp: Date.now()
      } as any;

      const result = converter.convert(breadcrumb);
      expect(result).assertUndefined();
    });

    it('should handle sentry.transaction category', 0, () => {
      const breadcrumb = {
        category: 'sentry.transaction',
        message: 'Test transaction',
        level: 'info',
        timestamp: Date.now()
      } as any;

      const result = converter.convert(breadcrumb);
      expect(result).assertUndefined();
    });

    it('should handle http category', 0, () => {
      const breadcrumb = {
        category: 'http',
        message: 'HTTP request',
        level: 'info',
        timestamp: Date.now(),
        data: {
          method: 'GET',
          url: 'https://example.com',
          status_code: 200
        }
      } as any;

      const result = converter.convert(breadcrumb);
      expect(result).assertInstanceOf(Object);
    });

    it('should handle navigation category with valid data', 0, () => {
      const breadcrumb = {
        category: 'navigation',
        message: 'Navigation event',
        level: 'info',
        timestamp: Date.now(),
        data: {
          to: 'https://example.com/page'
        }
      } as any;

      const result = converter.convert(breadcrumb);
      expect(result).assertInstanceOf(Object);
    });

    it('should handle navigation category with invalid data', 0, () => {
      const breadcrumb = {
        category: 'navigation',
        message: 'Navigation event',
        level: 'info',
        timestamp: Date.now(),
        data: {
          to: null
        }
      } as any;

      const result = converter.convert(breadcrumb);
      expect(result).assertUndefined();
    });

    it('should handle ui.click category', 0, () => {
      const breadcrumb = {
        category: 'ui.click',
        message: 'UI click',
        level: 'info',
        timestamp: Date.now(),
        data: {
          element: 'button',
          text: 'Click me'
        }
      } as any;

      const result = converter.convert(breadcrumb);
      expect(result).assertInstanceOf(Object);
    });

    it('should handle ui.input category', 0, () => {
      const breadcrumb = {
        category: 'ui.input',
        message: 'UI input',
        level: 'info',
        timestamp: Date.now(),
        data: {
          element: 'input',
          value: 'test value'
        }
      } as any;

      const result = converter.convert(breadcrumb);
      expect(result).assertInstanceOf(Object);
    });

    it('should handle console category', 0, () => {
      const breadcrumb = {
        category: 'console',
        message: 'Console log',
        level: 'info',
        timestamp: Date.now()
      } as any;

      const result = converter.convert(breadcrumb);
      expect(result).assertInstanceOf(Object);
    });

    it('should handle default category', 0, () => {
      const breadcrumb = {
        category: 'custom',
        message: 'Custom event',
        level: 'info',
        timestamp: Date.now()
      } as any;

      const result = converter.convert(breadcrumb);
      expect(result).assertInstanceOf(Object);
    });

    it('should handle breadcrumb with missing data', 0, () => {
      const breadcrumb = {
        category: 'http',
        message: 'HTTP request',
        level: 'info',
        timestamp: Date.now()
      } as any;

      const result = converter.convert(breadcrumb);
      expect(result).assertInstanceOf(Object);
    });

    it('should handle breadcrumb with empty data', 0, () => {
      const breadcrumb = {
        category: 'http',
        message: 'HTTP request',
        level: 'info',
        timestamp: Date.now(),
        data: {}
      } as any;

      const result = converter.convert(breadcrumb);
      expect(result).assertInstanceOf(Object);
    });
  });
}
