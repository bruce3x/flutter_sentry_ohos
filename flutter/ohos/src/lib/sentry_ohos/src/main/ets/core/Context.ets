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

import connection from '@ohos.net.connection';
import display from '@ohos.display';
import storageStatistics from '@ohos.file.storageStatistics';
import process from '@ohos.process';
import batteryInfo from '@ohos.batteryInfo';
import hidebug from '@ohos.hidebug';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { bundleManager } from '@kit.AbilityKit';
// 额外尝试读取更丰富的构建信息（若模块可用）
// 一些版本中 @ohos.deviceInfo 暴露 buildVersion/softwareModel
// 若不可用，try-catch 将吞掉错误，保持兼容
// 避免将命名空间当作对象访问，暂不直接使用 @ohos.deviceInfo 额外字段
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';

type Primitive = string | number | boolean | null | undefined;

export interface DeviceContext {
  model?: string;
  brand?: string;
  os?: string;
  osVersion?: string;
  manufacturer?: string;
  kernelVersion?: string;
  processorCount?: number;
  archs?: Array<string>;
  chipset?: string;
}

export interface AppContext {
  appName?: string;
  appVersion?: string;
  packageName?: string;
  appBuild?: string | number;
}

export interface AppPermissionsDetail {
  requested?: Array<string>;
  granted?: Array<string>;
}

export interface SamplingOptions {
  tracesSampleRate?: number; // 0~1，控制 span 上报
  errorsSampleRate?: number; // 0~1，控制异常/消息上报
}

export function collectDeviceContext(): Record<string, Primitive> {
  // 无外部依赖的安全实现：默认返回空
  const ctx: Record<string, Primitive> = {};
  try {
    // 使用 BasicServicesKit 的 deviceInfo
    const osName: string = 'OpenHarmony';
    ctx['os'] = osName;
    try { const model = deviceInfo.productModel; if (model) ctx['model'] = model; } catch (_) {}
    try { const brand = deviceInfo.manufacture; if (brand) ctx['brand'] = brand; } catch (_) {}
    // family/model_id/id：若无明确来源则用 model 回退
    try { const model = deviceInfo.productModel; if (model && !ctx['family']) ctx['family'] = model; if (model && !ctx['modelId']) ctx['modelId'] = model; if (model && !ctx['id']) ctx['id'] = model; } catch (_) {}
    try { const osVersion = deviceInfo.osFullName; if (osVersion) ctx['osVersion'] = osVersion; } catch (_) {}
    // 补充系统构建号与版本 ID（用于 os.build / os.id）
    try { const disp = deviceInfo.displayVersion; if (disp) ctx['build'] = disp; } catch (_) {}
    try { const vid = deviceInfo.versionId; if (vid) ctx['versionId'] = vid; } catch (_) {}
    try { const manuf = deviceInfo.manufacture; if (manuf) ctx['manufacturer'] = manuf; } catch (_) {}
    try { const kv = getKernelVersion(); if (kv) ctx['kernelVersion'] = kv; } catch (_) {}
    try { const pc = getProcessorCount(); if (pc !== undefined) ctx['processorCount'] = pc; } catch (_) {}

    // 补充 Android 对齐的字段
    try {
      // 设备名称（回退到 localhost）
      ctx['name'] = 'localhost';
    } catch (_) {}

    try {
      // 屏幕信息
      const def = display.getDefaultDisplaySync();
      if (def) {
        const dinfo = def as DisplayInfoLike;
        if (typeof dinfo.width === 'number') ctx['screen_width_pixels'] = dinfo.width;
        if (typeof dinfo.height === 'number') ctx['screen_height_pixels'] = dinfo.height;
        if (typeof dinfo.densityDPI === 'number') ctx['screen_dpi'] = dinfo.densityDPI;
        if (typeof dinfo.densityPixels === 'number') ctx['screen_density'] = dinfo.densityPixels;
      }
    } catch (_) {}

    try {
      // 电池信息
      const soc: number = batteryInfo.batterySOC;
      if (typeof soc === 'number') ctx['battery_level'] = Math.max(0, Math.min(100, Math.floor(soc)));
      const chargeState = batteryInfo.chargingStatus;
      ctx['charging'] = chargeState === 1;
      // 电池温度（转换为摄氏度）
      try {
        const batteryTemp = batteryInfo.batteryTemperature;
        if (typeof batteryTemp === 'number') ctx['battery_temperature'] = batteryTemp / 10;
      } catch (_) {}
    } catch (_) {}

    try {
      // 网络连接类型
      const net = connection.getDefaultNetSync();
      const caps = connection.getNetCapabilitiesSync(net);
      if (caps && caps.bearerTypes && caps.bearerTypes.indexOf(connection.NetBearType.BEARER_WIFI) >= 0) {
        ctx['connection_type'] = 'wifi';
      } else if (caps && caps.bearerTypes && caps.bearerTypes.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0) {
        ctx['connection_type'] = 'cellular';
      } else {
        ctx['connection_type'] = 'unknown';
      }
      ctx['online'] = caps && caps.bearerTypes && caps.bearerTypes.length > 0;

      // 网络带宽信息
      try {
        if (caps && caps.linkUpBandwidthKbps !== undefined) {
          ctx['upload_bandwidth'] = caps.linkUpBandwidthKbps;
        }
        if (caps && caps.linkDownBandwidthKbps !== undefined) {
          ctx['download_bandwidth'] = caps.linkDownBandwidthKbps;
        }
      } catch (_) {}

      // VPN状态 - 通过检查网络类型判断
      try {
        // VPN 连接通常在 bearerTypes 中会特殊标识，这里简化为 false
        // 实际实现中可能需要使用其他 API 来检测 VPN
        ctx['vpn_active'] = false;
      } catch (_) {}
    } catch (_) {}

    try {
      // 内存信息
      let memFound = false;
      try {
        const mem = hidebug.getSystemMemInfo();
        if (mem && typeof mem.totalMem === 'bigint') {
           // 新版 API 可能返回 bigint (单位 kB)
           const totalBytes = Number(mem.totalMem) * 1024;
           const freeBytes = Number(mem.availableMem) * 1024;
           ctx['memory_size'] = totalBytes;
           ctx['free_memory'] = freeBytes;
           memFound = true;
        } else if (mem && typeof mem.totalMem === 'number' && typeof mem.availableMem === 'number') {
           // 旧版 API 返回 number (单位 kB)
           const totalBytes = (mem.totalMem as number) * 1024;
           const freeBytes = (mem.availableMem as number) * 1024;
           ctx['memory_size'] = totalBytes;
           ctx['free_memory'] = freeBytes;
           memFound = true;
        }
      } catch (_) {}

      if (!memFound) {
        const meminfo = tryReadText('/proc/meminfo');
        if (meminfo !== undefined) {
          const parsed = parseMemInfo(meminfo);
          if (parsed.totalKb !== undefined) {
            const totalBytes = parsed.totalKb * 1024;
            ctx['memory_size'] = totalBytes;
            if (parsed.availableKb !== undefined) {
              const freeBytes = parsed.availableKb * 1024;
              ctx['free_memory'] = freeBytes;
            }
          }
        }
      }
    } catch (_) {}

    try {
      // 存储信息
      let totalBytes: number | undefined = undefined;
      let freeBytes: number | undefined = undefined;
      if (deviceInfo.sdkApiVersion >= 15) {
        if (typeof storageStatistics.getTotalSizeSync === 'function') {
          totalBytes = storageStatistics.getTotalSizeSync();
        }
        if (typeof storageStatistics.getFreeSizeSync === 'function') {
          freeBytes = storageStatistics.getFreeSizeSync();
        }
        if (typeof totalBytes === 'number') ctx['storage_size'] = totalBytes;
        if (typeof freeBytes === 'number') ctx['free_storage'] = freeBytes;
      }

    } catch (_) {}

    try {
      // 开机时间
      const uptimeTxt = tryReadText('/proc/uptime');
      if (uptimeTxt !== undefined) {
        const secStr = uptimeTxt.split(' ')[0];
        const secs = parseFloat(secStr);
        if (!isNaN(secs)) {
          const bootMs = Date.now() - Math.floor(secs * 1000);
          ctx['boot_time'] = new Date(bootMs).toISOString();
        }
      }
    } catch (_) {}

    try {
      // 处理器频率
      const cpuinfo = tryReadText('/proc/cpuinfo');
      if (cpuinfo) {
        const mhzLine = cpuinfo.split('\n').find((l) => l.toLowerCase().indexOf('cpu mhz') >= 0 || l.toLowerCase().indexOf('bogomips') >= 0);
        if (mhzLine) {
          const num = parseFloat(mhzLine.replace(/[^0-9.]/g, ''));
          if (!isNaN(num)) ctx['processor_frequency'] = Math.floor(num);
        }
      }
    } catch (_) {}

    try {
      // 语言环境
      const localeInfo = getLocaleTimezone();
      if (localeInfo.locale) ctx['locale'] = localeInfo.locale;
      if (localeInfo.timezone) ctx['timezone'] = localeInfo.timezone;
    } catch (_) {}

    try {
      // 屏幕方向（默认 portrait）
      ctx['orientation'] = 'portrait';
    } catch (_) {}

    try {
      // 模拟器状态（默认 false）
      ctx['simulator'] = false;
    } catch (_) {}

    try {
      // 低内存状态
      if (typeof ctx['memory_size'] === 'number' && typeof ctx['free_memory'] === 'number') {
        const freeMb = (ctx['free_memory'] as number) / (1024 * 1024);
        const totalMb = (ctx['memory_size'] as number) / (1024 * 1024);
        ctx['low_memory'] = (freeMb / totalMb) < 0.1;
      }
    } catch (_) {}

    // 构建号与软件型号（若 SDK 暴露则读取，否则跳过）
    // 去除对命名空间的对象化访问，改为从 /proc 或其它已采集信息推断（若未来 SDK 暴露则补充）
    // systemParameter 回退补充：避免直接依赖，尝试读取 /proc/version 等
    try {
      const verTxt = tryReadText('/proc/version');
      if (verTxt && !ctx['osVersion']) ctx['osVersion'] = verTxt.split('\n')[0];
    } catch (_) {}
    try {
      // 优先使用 deviceInfo 获取支持的 ABI 列表
      try {
        const abiList = deviceInfo.abiList;
        if (abiList && abiList.length > 0) {
          ctx['archs'] = abiList;
        }
      } catch (_) {}

      // 解析 /proc/cpuinfo 以推断 chipset，如果 archs 还没获取到则一并尝试获取
      const cpuinfo = tryReadText('/proc/cpuinfo');
      if (cpuinfo) {
        if (!ctx['archs']) {
            const isArm64 = cpuinfo.indexOf('AArch64') >= 0 || cpuinfo.indexOf('ARMv8') >= 0 || cpuinfo.toLowerCase().indexOf('armv8') >= 0;
            const archs: Array<string> = isArm64 ? ['arm64-v8a', 'armeabi-v7a', 'armeabi'] : ['armeabi-v7a', 'armeabi'];
            ctx['archs'] = archs.join(','); // 序列化阶段转换为数组
        }
        // 提取 Hardware/Model 字段作为简化的 chipset
        const lines = cpuinfo.split('\n');
        for (let i = 0; i < lines.length; i++) {
          const ln = lines[i];
          if (ln.toLowerCase().startsWith('hardware') || ln.toLowerCase().startsWith('model name')) {
            const kv = ln.split(':');
            if (kv.length >= 2) {
              const val = kv.slice(1).join(':').trim();
              if (val.length > 0) ctx['chipset'] = val;
              break;
            }
          }
        }
      }
    } catch (_) {}
  } catch (_) {}
  return ctx;
}

export function collectAppContext(): Record<string, Primitive> {
  if (_appCtxCache) return _appCtxCache;
  // 返回空对象作为占位，同时异步初始化缓存
  const ctx: Record<string, Primitive> = {};
  initAppContextIfNeeded();
  return ctx;
}

export interface RuntimeContext {
  networkType?: string; // wifi/cellular/none/unknown
  batteryLevel?: number; // 0~100
  isCharging?: boolean;
  memoryUsedMb?: number;
  memoryTotalMb?: number;
  foregroundPage?: string;
  cpuLoadAvg1min?: number;
  cpuUsagePercent?: number;
  bootTime?: string;
  lowMemory?: boolean;
  freeMemoryMb?: number;
  online?: boolean;
  arch?: string;
  cpuFrequencyMHz?: number;
  screenDpi?: number;
  screenDensity?: number;
  screenWidthPx?: number;
  screenHeightPx?: number;
  storageTotalGb?: number;
  storageFreeGb?: number;
}

/**
 * 近似 rooted 判断：若存在常见 su 路径、或 /system/bin/su 可访问，则判定为 rooted=true。
 * 注意：此方法仅作启发式，可能存在误判。
 */
export function detectRooted(): boolean | undefined {
  try {
    const paths: Array<string> = [
      '/system/bin/su',
      '/system/xbin/su',
      '/sbin/su',
      '/vendor/bin/su',
      '/su/bin/su',
    ];
    for (let i = 0; i < paths.length; i++) {
      const p = paths[i];
      const txt = tryReadText(p);
      if (txt !== undefined) return true;
    }
  } catch (_) {}
  return undefined;
}

export interface LocaleTimeZoneInfo {
  locale?: string;
  timezone?: string;
  language?: string;
}

interface MemInfo {
  totalKb?: number;
  availableKb?: number;
}

// 兼容显示信息对象的可能字段（不同系统版本字段名可能不同）
interface DisplayInfoLike { densityDPI?: number; densityPixels?: number; width?: number; height?: number }
// 兼容存储统计（按卷）
interface StorageStatsWithVolume { getTotalSizeSync?: (id: string) => number; getFreeSizeSync?: (id: string) => number }
// 兼容存储统计（无参）
interface StorageStatsNoVolume { getTotalBytesSync?: () => number; getFreeBytesSync?: () => number }

export function collectRuntimeContext(): RuntimeContext {
  const info: RuntimeContext = {};
  try {
    // 网络（同步近似，若 API 不可用将抛异常进入 catch）
    try {
      const net = connection.getDefaultNetSync();
      const caps = connection.getNetCapabilitiesSync(net);
      let networkType: string | undefined = undefined;
      if (caps && caps.bearerTypes && caps.bearerTypes.indexOf(connection.NetBearType.BEARER_WIFI) >= 0) networkType = 'wifi';
      else if (caps && caps.bearerTypes && caps.bearerTypes.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0) networkType = 'cellular';
      else if (caps && caps.bearerTypes && caps.bearerTypes.length === 0) networkType = 'none';
      else networkType = 'unknown';
      info.networkType = networkType;
      info.online = networkType !== 'none';
    } catch (_) {}
  } catch (_) {}
  try {
    // 电量/充电
    try {
      const soc: number = batteryInfo.batterySOC;;
      info.batteryLevel = typeof soc === 'number' ? Math.max(0, Math.min(100, Math.floor(soc))) : undefined;
    } catch (_) {}
    try {
      const chargeState = batteryInfo.chargingStatus;;
      // 常见枚举：0-未知 1-正在充电 2-未充电 ...（不同版本可能不同）
      info.isCharging = chargeState === 1;
    } catch (_) {}
  } catch (_) {}
  try {
    // 内存
    // 例如可集成 @ohos.resourceStatistics 或进程内存接口
    try {
      // 优先尝试 hidebug
      let memFound = false;
      try {
         const mem = hidebug.getSystemMemInfo();
         if (mem) {
            // memoryTotalMb
            const totalKb = typeof mem.totalMem === 'bigint' ? Number(mem.totalMem) : (mem.totalMem as number);
            const freeKb = typeof mem.freeMem === 'bigint' ? Number(mem.freeMem) : (mem.freeMem as number);

            info.memoryTotalMb = Math.floor(totalKb / 1024);

            const usedKb = totalKb - freeKb;
            info.memoryUsedMb = Math.floor(usedKb / 1024);
            memFound = true;
         }
      } catch (_) {}

      if (!memFound) {
        // 优先尝试读取 /proc/meminfo（部分设备可能不可用）
        const meminfo = tryReadText('/proc/meminfo');
        if (meminfo !== undefined) {
          const parsed = parseMemInfo(meminfo);
          if (parsed.totalKb !== undefined) info.memoryTotalMb = Math.floor(parsed.totalKb / 1024);
          if (parsed.availableKb !== undefined) {
            const usedKb = parsed.totalKb !== undefined ? (parsed.totalKb - parsed.availableKb) : undefined;
            if (usedKb !== undefined) info.memoryUsedMb = Math.floor(usedKb / 1024);
          }
        } else {
          // 回退到 JS heap 估算
          interface PerfMemory { usedJSHeapSize?: number; jsHeapSizeLimit?: number }
          interface Perf { memory?: PerfMemory }
          interface GlobalWithPerf { performance?: Perf }
          const gp = globalThis as GlobalWithPerf;
          const used = gp.performance?.memory?.usedJSHeapSize;
          const total = gp.performance?.memory?.jsHeapSizeLimit;
          if (typeof used === 'number') info.memoryUsedMb = Math.floor(used / (1024 * 1024));
          if (typeof total === 'number') info.memoryTotalMb = Math.floor(total / (1024 * 1024));
        }
      }
    } catch (_) {}
  } catch (_) {}
  try {
    // 前台页面
    // 可通过 UI 框架当前页面路由或自维护变量记录
    info.foregroundPage = _foregroundPage;
  } catch (_) {}
  try {
    // 开机时间
    const uptimeTxt = tryReadText('/proc/uptime');
    if (uptimeTxt !== undefined) {
      const secStr = uptimeTxt.split(' ')[0];
      const secs = parseFloat(secStr);
      if (!isNaN(secs)) {
        const bootMs = Date.now() - Math.floor(secs * 1000);
        info.bootTime = new Date(bootMs).toISOString();
      }
    }
  } catch (_) {}
  try {
    // 低内存判断
    if (typeof info.memoryTotalMb === 'number' && typeof info.memoryUsedMb === 'number') {
      const freeMb = info.memoryTotalMb - info.memoryUsedMb;
      if (freeMb >= 0) info.lowMemory = (freeMb / info.memoryTotalMb) < 0.1;
      if (typeof info.freeMemoryMb !== 'number') info.freeMemoryMb = freeMb;
    }
  } catch (_) {}
  try {
    // CPU 负载（1 分钟平均），来源 /proc/loadavg
    const loadavg = tryReadText('/proc/loadavg');
    if (loadavg !== undefined) {
      const val = parseFloat(loadavg.split(' ')[0]);
      if (!isNaN(val)) info.cpuLoadAvg1min = val;
    }
  } catch (_) {}
  try {
    // 处理器架构/频率（基于 /proc/cpuinfo）
    const cpuinfo = tryReadText('/proc/cpuinfo');
    if (cpuinfo) {
      const isArm64 = cpuinfo.indexOf('AArch64') >= 0 || cpuinfo.indexOf('ARMv8') >= 0;
      info.arch = isArm64 ? 'arm64' : 'arm';
      const mhzLine = cpuinfo.split('\n').find((l) => l.toLowerCase().indexOf('cpu mhz') >= 0 || l.toLowerCase().indexOf('bogomips') >= 0);
      if (mhzLine) {
        const num = parseFloat(mhzLine.replace(/[^0-9.]/g, ''));
        if (!isNaN(num)) info.cpuFrequencyMHz = Math.floor(num);
      }
    }
  } catch (_) {}
  try {
    // 屏幕信息：DPI/密度/分辨率
    const def = display.getDefaultDisplaySync();
    if (def) {
      const dinfo = def as DisplayInfoLike;
      const densityDpi = dinfo.densityDPI;
      const densityPx = dinfo.densityPixels;
      const width = dinfo.width;
      const height = dinfo.height;
      if (typeof densityDpi === 'number') info.screenDpi = densityDpi;
      if (typeof densityPx === 'number') info.screenDensity = densityPx;
      if (typeof width === 'number') info.screenWidthPx = width;
      if (typeof height === 'number') info.screenHeightPx = height;
    }
  } catch (_) {}
  try {
    // 存储空间：总量/可用（单位 GB），依据 d.ts 使用无参同步接口
    let totalBytes: number | undefined = undefined;
    let freeBytes: number | undefined = undefined;
    try {
      if (typeof storageStatistics.getTotalSizeSync === 'function') {
        totalBytes = storageStatistics.getTotalSizeSync();
      }
    } catch (_) {}
    try {
      if (typeof storageStatistics.getFreeSizeSync === 'function') {
        freeBytes = storageStatistics.getFreeSizeSync();
      }
    } catch (_) {}
    if (typeof totalBytes === 'number') info.storageTotalGb = Math.round((totalBytes / (1024 * 1024 * 1024)) * 10) / 10;
    if (typeof freeBytes === 'number') info.storageFreeGb = Math.round((freeBytes / (1024 * 1024 * 1024)) * 10) / 10;
  } catch (_) {}
  try {
    // CPU 使用率（近似）：回退读取 /proc/stat 估算
    const stat = tryReadText('/proc/stat');
    if (stat) {
      const first = stat.split('\n')[0];
      const parts = first.trim().split(/\s+/);
      if (parts[0] === 'cpu') {
        const nums: Array<number> = [];
        for (let i = 1; i < parts.length; i++) {
          const n = parseInt(parts[i]);
          if (!isNaN(n)) nums.push(n);
        }
        if (nums.length >= 4) {
          const user = nums[0];
          const nice = nums[1];
          const system = nums[2];
          const idle = nums[3];
          const total = user + nice + system + idle;
          if (total > 0) {
            const busy = user + nice + system;
            info.cpuUsagePercent = Math.round((busy / total) * 100);
          }
        }
      }
    }
  } catch (_) {}
  return info;
}

let _foregroundPage: string | undefined = undefined;
export function updateForegroundPage(name: string): void {
  _foregroundPage = name;
}

// App 上下文缓存与初始化
let _appCtxCache: Record<string, Primitive> | null = null;
let _appCtxInitStarted: boolean = false;

interface LocalBundleInfo { name?: string; bundleName?: string; versionName?: string; versionCode?: number; appInfo?: LocalAppInfo }
interface LocalAppInfo { permissions?: Array<string> }

function initAppContextIfNeeded(): void {
  if (_appCtxInitStarted) return;
  _appCtxInitStarted = true;
  try {
    const flags = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION | bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_METADATA;
    bundleManager.getBundleInfoForSelf(flags).then((data) => {
      try {
        const info = (data as LocalBundleInfo);
        const appNameValue = info.name !== undefined ? info.name : info.bundleName;
        const cache: Record<string, Primitive> = {};

        // 基础应用信息
        if (appNameValue !== undefined) cache['app_name'] = appNameValue;
        if (info.bundleName !== undefined) cache['app_identifier'] = info.bundleName;
        if (info.versionName !== undefined) cache['app_version'] = info.versionName;
        if (info.versionCode !== undefined) cache['app_build'] = info.versionCode;

        // 补充 Android 对齐的字段
        cache['in_foreground'] = true;
        cache['text_scale'] = 1.0;
        cache['is_split_apks'] = false;

        // 应用启动时间（当前时间作为近似值）
        cache['app_start_time'] = new Date().toISOString();

        // 视图名称列表（从运行时上下文获取）
        try {
          const runtimeCtx = collectRuntimeContext();
          if (typeof runtimeCtx.foregroundPage === 'string' && runtimeCtx.foregroundPage) {
            cache['view_names'] = runtimeCtx.foregroundPage;
          }
        } catch (_) {}

        // 应用内存使用（从运行时上下文获取）
        try {
          const runtimeCtx = collectRuntimeContext();
          if (typeof runtimeCtx.memoryUsedMb === 'number') {
            cache['app_memory'] = runtimeCtx.memoryUsedMb * 1024 * 1024; // 转换为字节
          }
        } catch (_) {}

        // 权限信息（转换为键值对格式以对齐 Android）
        if (info.appInfo && info.appInfo.permissions && info.appInfo.permissions.length > 0) {
          // 创建 the permissions map 格式：{permission: 'granted'}
          const permissionsMap: Record<string, string> = {};
          for (let i = 0; i < info.appInfo.permissions.length; i++) {
            const perm = info.appInfo.permissions[i];
            permissionsMap[perm] = 'granted';
          }
          // 缓存为JSON字符串，后续序列化时解析
          cache['permissionsJson'] = JSON.stringify(permissionsMap);
        }
        _appCtxCache = cache;
      } catch (_) {
        _appCtxCache = {};
      }
    }).catch((err: BusinessError) => {
      console.error(`[Sentry_ohos_core], [Context], getBundleInfoForSelf failed. Cause: %{public}s ${err.message}`);
      _appCtxCache = {};
    });
  } catch (err) {
    const message = (err as BusinessError).message;
    console.error('[Sentry_ohos_core]', '[Context]', 'getBundleInfoForSelf failed. Cause: %{public}s', message);
    _appCtxCache = {};
  }
}

// helpers
// 移除 systemParameter 依赖，保留空函数避免引用错误（不再使用）
function safeGetSystemParameter(_: Array<string>): string | undefined { return undefined; }

function tryReadText(path: string): string | undefined {
  try {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(file.fd);
      const size = stat.size as number;
      const buf = new ArrayBuffer(size);
      const read = fs.readSync(file.fd, buf);
      if (read > 0) {
        const dec: util.TextDecoder = new util.TextDecoder('utf-8');
        const u8 = new Uint8Array(buf);
        return dec.decode(u8);
      }
    } finally {
      fs.closeSync(file);
    }
  } catch (_) {}
  return undefined;
}

function parseMemInfo(text: string): MemInfo {
  const lines = text.split('\n');
  let totalKb: number | undefined = undefined;
  let availableKb: number | undefined = undefined;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith('MemTotal:')) {
      const m = line.match(/MemTotal:\s+(\d+) kB/);
      if (m && m[1]) totalKb = parseInt(m[1]);
    } else if (line.startsWith('MemAvailable:')) {
      const m2 = line.match(/MemAvailable:\s+(\d+) kB/);
      if (m2 && m2[1]) availableKb = parseInt(m2[1]);
    }
  }
  return { totalKb: totalKb, availableKb: availableKb };
}

export function getKernelVersion(): string | undefined {
  try {
    const txt = tryReadText('/proc/version');
    if (txt !== undefined) return txt.split('\n')[0];
  } catch (_) {}
  // 回退：无 systemParameter，返回 undefined
  return undefined;
}

export function getProcessorCount(): number | undefined {
  try {
    const txt = tryReadText('/proc/cpuinfo');
    if (txt !== undefined) {
      const lines = txt.split('\n');
      let count = 0;
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (line.startsWith('processor')) count++;
      }
      return count > 0 ? count : undefined;
    }
  } catch (_) {}
  return undefined;
}

export function getLocaleTimezone(): LocaleTimeZoneInfo {
  const out: LocaleTimeZoneInfo = {
    locale: i18n.System.getSystemLocale(),
    timezone: i18n.getTimeZone().getID(),
    language: i18n.System.getSystemLanguage()
  };
  return out;
}

export function shouldSample(rate: number | undefined): boolean {
  if (rate === undefined) return true;
  if (rate <= 0) return false;
  if (rate >= 1) return true;
  // 简易采样：使用时间戳近似
  const mod = new Date().getTime() % 1000;
  const threshold = Math.floor(rate * 1000);
  return mod < threshold;
}


