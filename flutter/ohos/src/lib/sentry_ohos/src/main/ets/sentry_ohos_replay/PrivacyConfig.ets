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

export class PrivacyConfig {
  private maskInputs: boolean;
  private maskImages: boolean = false;
  private maskedComponentIds: Set<string> = new Set();
  private unmaskedComponentIds: Set<string> = new Set();

  constructor(maskInputs: boolean = true) {
    this.maskInputs = maskInputs;
  }

  public maskText(text: string): string {
    return this.maskInputs ? "*".repeat(text.length) : text;
  }

  public enableMasking(): void {
    this.maskInputs = true;
  }

  public disableMasking(): void {
    this.maskInputs = false;
  }

  // 全局：是否遮罩所有图像（快照/截图内容）
  public setMaskAllImages(enabled: boolean): void {
    this.maskImages = enabled;
  }

  public isMaskAllImages(): boolean {
    return this.maskImages;
  }

  public maskComponent(id: string): void {
    this.maskedComponentIds.add(id);
    this.unmaskedComponentIds.delete(id);
  }

  public unmaskComponent(id: string): void {
    this.unmaskedComponentIds.add(id);
    this.maskedComponentIds.delete(id);
  }

  public clearComponentMasking(id: string): void {
    this.maskedComponentIds.delete(id);
    this.unmaskedComponentIds.delete(id);
  }

  public shouldMaskComponent(id: string): boolean {
    if (this.unmaskedComponentIds.has(id)) return false;
    if (this.maskedComponentIds.has(id)) return true;
    return this.maskInputs;
  }
}
