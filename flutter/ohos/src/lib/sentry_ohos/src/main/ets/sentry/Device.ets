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

export class Device {
  name?: string;
  family?: string;
  model?: string;
  modelId?: string;
  arch?: string;
  batteryLevel?: number;
  orientation?: string;
  manufacturer?: string;
  brand?: string;
  screenResolution?: string;
  screenDpi?: number;
  screenDensity?: number;
  isCharging?: boolean;
  isOnline?: boolean;
  bootTime?: string;
  timezone?: string;
  locale?: string;
  id?: string;
  language?: string;
  connectionType?: string;
  freeMemory?: number;
  memorySize?: number;
  freeStorage?: number;
  storageSize?: number;
  simulator?: boolean;
  deviceType?: string;
  cpuDescription?: string;
  processorCount?: number;
  processorFrequency?: number;
  batteryTemperature?: number;

  constructor(init?: Partial<Device>) {
    if (!init) return;
    if (init.name !== undefined) this.name = init.name;
    if (init.family !== undefined) this.family = init.family;
    if (init.model !== undefined) this.model = init.model;
    if (init.modelId !== undefined) this.modelId = init.modelId;
    if (init.arch !== undefined) this.arch = init.arch;
    if (init.batteryLevel !== undefined) this.batteryLevel = init.batteryLevel;
    if (init.orientation !== undefined) this.orientation = init.orientation;
    if (init.manufacturer !== undefined) this.manufacturer = init.manufacturer;
    if (init.brand !== undefined) this.brand = init.brand;
    if (init.screenResolution !== undefined) this.screenResolution = init.screenResolution;
    if (init.screenDpi !== undefined) this.screenDpi = init.screenDpi;
    if (init.screenDensity !== undefined) this.screenDensity = init.screenDensity;
    if (init.isCharging !== undefined) this.isCharging = init.isCharging;
    if (init.isOnline !== undefined) this.isOnline = init.isOnline;
    if (init.bootTime !== undefined) this.bootTime = init.bootTime;
    if (init.timezone !== undefined) this.timezone = init.timezone;
    if (init.locale !== undefined) this.locale = init.locale;
    if (init.id !== undefined) this.id = init.id;
    if (init.language !== undefined) this.language = init.language;
    if (init.connectionType !== undefined) this.connectionType = init.connectionType;
    if (init.freeMemory !== undefined) this.freeMemory = init.freeMemory;
    if (init.memorySize !== undefined) this.memorySize = init.memorySize;
    if (init.freeStorage !== undefined) this.freeStorage = init.freeStorage;
    if (init.storageSize !== undefined) this.storageSize = init.storageSize;
    if (init.simulator !== undefined) this.simulator = init.simulator;
    if (init.deviceType !== undefined) this.deviceType = init.deviceType;
    if (init.cpuDescription !== undefined) this.cpuDescription = init.cpuDescription;
    if (init.processorCount !== undefined) this.processorCount = init.processorCount;
    if (init.processorFrequency !== undefined) this.processorFrequency = init.processorFrequency;
    if (init.batteryTemperature !== undefined) this.batteryTemperature = init.batteryTemperature;
  }
}




