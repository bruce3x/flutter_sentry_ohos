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

import { TextInputComponent } from './Component';
import { ReplayEvent, InputEventData, FocusEventData, BlurEventData  } from './ReplayEvent';
import { PrivacyConfig } from './PrivacyConfig';

interface InputOffHandler {
  change?: (value: string) => void;
  focus?: () => void;
  blur?: () => void;
}

export class InputCapture {
  private inputs: TextInputComponent[];
  private capturedEvents: ReplayEvent[] = [];
  private privacy: PrivacyConfig;
  private offHandlers: Map<string, InputOffHandler> = new Map();

  constructor(inputs: TextInputComponent[], privacy: PrivacyConfig) {
    this.inputs = inputs;
    this.privacy = privacy;
  }

  /**
   * 开始捕获输入事件
   */
  public startCapture(): void {
    this.inputs.forEach((input) => {
      const onChange = (value: string) => {
        const event: ReplayEvent = {
          type: "input",
          timestamp: Date.now(),
          data: { componentId: input.id, value: this.privacy.maskText(value) } as InputEventData
        };
        this.capturedEvents.push(event);
      };

      const onFocus = () => {
        const event: ReplayEvent = {
          type: "focus",
          timestamp: Date.now(),
          data: { componentId: input.id } as FocusEventData
        };
        this.capturedEvents.push(event);
      };

      const onBlur = () => {
        const event: ReplayEvent = {
          type: "blur",
          timestamp: Date.now(),
          data: { componentId: input.id } as BlurEventData
        };
        this.capturedEvents.push(event);
      };

      input.onChange(onChange);
      input.onFocus(onFocus);
      input.onBlur(onBlur);
      this.offHandlers.set(input.id, { change: onChange, focus: onFocus, blur: onBlur });
    });
  }

  /**
   * 获取捕获到的所有事件
   */
  public getCapturedEvents(): ReplayEvent[] {
    return this.capturedEvents;
  }

  /**
   * 清空事件缓存
   */
  public clearCapturedEvents(): void {
    this.capturedEvents = [];
  }

  /** 停止捕获（可选解除绑定） */
  public stopCapture(): void {
    this.offHandlers.forEach((handlers, id) => {
      const input = this.inputs.find(i => i.id === id);
      if (!input || !handlers) return;
      if (handlers.change && input.offChange) input.offChange(handlers.change);
      if (handlers.focus && input.offFocus) input.offFocus(handlers.focus);
      if (handlers.blur && input.offBlur) input.offBlur(handlers.blur);
    });
    this.offHandlers.clear();
  }
}
