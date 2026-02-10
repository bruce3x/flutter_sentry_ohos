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
import batteryInfo from '@ohos.batteryInfo';
import { BreadcrumbStore, Breadcrumb, SentryLevel } from '../sentry/Breadcrumb';

interface NetCapsShape {
  bearerTypes?: Array<number>;
  downlinkBandwidthKbps?: number;
  uplinkBandwidthKbps?: number;
  signalStrength?: number;
}
interface NetSnapshot {
  connected: boolean;
  network_type: string; // wifi/cellular/none/unknown
  download_bandwidth?: number;
  upload_bandwidth?: number;
  signal_strength?: number;
}

export class AutoBreadcrumbs {
  private store: BreadcrumbStore;
  private netTimer?: number;
  private batTimer?: number;
  private lastBatteryLevel?: number;
  private lastCharging?: boolean;
  private lastNet?: NetSnapshot;

  constructor(store: BreadcrumbStore) {
    this.store = store;
  }

  start(): void {
    // 轮询网络状态（兼容类型定义无 on/off 的环境）
    try {
      this.pollNetwork(true);
      this.netTimer = setInterval(() => this.pollNetwork(false), 15000) as number;
    } catch (_) {}

    // 电量/充电轮询（无监听则定时获取）
    try {
      this.pollBattery();
      this.batTimer = setInterval(() => this.pollBattery(), 30000) as number;
    } catch (_) {}

    // 添加应用生命周期 breadcrumb
    this.addAppLifecycleBreadcrumb('foreground');
  }

  stop(): void {
    if (this.netTimer !== undefined) {
      try { clearInterval(this.netTimer); } catch (_) {}
      this.netTimer = undefined;
    }
    if (this.batTimer !== undefined) {
      try { clearInterval(this.batTimer); } catch (_) {}
      this.batTimer = undefined;
    }
  }

  private addNetworkBreadcrumb(action: string): void {
    const bc = new Breadcrumb();
    bc.timestamp = new Date().toISOString();
    bc.message = 'Network Event';
    bc.category = 'network.event';
    bc.level = SentryLevel.Info;
    bc.type = 'system';
    const rec: Record<string, string> = {};
    rec['action'] = action;
    bc.data = rec;
    this.store.add(bc);
  }

  private pollBattery(): void {
    try {
      const levelRaw: number = batteryInfo.batterySOC;
      const level = Math.max(0, Math.min(100, Math.floor(levelRaw)));
      const charging = (batteryInfo.chargingStatus === 1);
      if (level !== this.lastBatteryLevel || charging !== this.lastCharging) {
        const bc = new Breadcrumb();
        bc.timestamp = new Date().toISOString();
        bc.message = 'Battery changed';
        bc.category = 'device.event';
        bc.level = SentryLevel.Info;
        bc.type = 'system';
        const rec: Record<string, string> = {};
        rec['action'] = 'BATTERY_CHANGED';
        rec['level'] = String(level);
        rec['charging'] = String(charging);
        bc.data = rec;
        this.store.add(bc);
        this.lastBatteryLevel = level;
        this.lastCharging = charging;
      }
    } catch (_) {}
  }

  private pollNetwork(initial: boolean): void {
    try {
      const snap = this.readNetworkSnapshot();
      if (!this.lastNet) {
        this.lastNet = snap;
        if (initial) {
          this.addNetworkBreadcrumb(snap.connected ? 'NETWORK_AVAILABLE' : 'NETWORK_LOST');
        }
        return;
      }
      // 可用性变化
      if (snap.connected !== this.lastNet.connected) {
        this.addNetworkBreadcrumb(snap.connected ? 'NETWORK_AVAILABLE' : 'NETWORK_LOST');
      }
      // 能力变化（类型或带宽/信号强度变化）
      const changedType = snap.network_type !== this.lastNet.network_type;
      const changedDl = snap.download_bandwidth !== this.lastNet.download_bandwidth;
      const changedUl = snap.upload_bandwidth !== this.lastNet.upload_bandwidth;
      const changedSig = snap.signal_strength !== this.lastNet.signal_strength;
      if (changedType || changedDl || changedUl || changedSig) {
        const rec: Record<string, string> = {};
        rec['network_type'] = snap.network_type;
        if (typeof snap.download_bandwidth === 'number') rec['download_bandwidth'] = String(snap.download_bandwidth);
        if (typeof snap.upload_bandwidth === 'number') rec['upload_bandwidth'] = String(snap.upload_bandwidth);
        if (typeof snap.signal_strength === 'number') rec['signal_strength'] = String(snap.signal_strength);
        const bc = new Breadcrumb();
        bc.timestamp = new Date().toISOString();
        bc.message = 'Network capabilities changed';
        bc.category = 'network.event';
        bc.level = SentryLevel.Info;
        bc.type = 'system';
        bc.data = rec;
        this.store.add(bc);
      }
      this.lastNet = snap;
    } catch (_) {}
  }

  private readNetworkSnapshot(): NetSnapshot {
    let connected = false;
    let type: string = 'unknown';
    let dl: number | undefined = undefined;
    let ul: number | undefined = undefined;
    let sig: number | undefined = undefined;
    try {
      const net = connection.getDefaultNetSync();
      const caps = connection.getNetCapabilitiesSync(net) as NetCapsShape;
      const types = Array.isArray(caps.bearerTypes) ? caps.bearerTypes as Array<number> : [];
      const isWifi = types.indexOf(connection.NetBearType.BEARER_WIFI) >= 0;
      const isCell = types.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0;
      if (isWifi) type = 'wifi';
      else if (isCell) type = 'cellular';
      else type = (types.length === 0 ? 'none' : 'unknown');
      connected = type !== 'none';
      if (typeof caps.downlinkBandwidthKbps === 'number') dl = caps.downlinkBandwidthKbps;
      if (typeof caps.uplinkBandwidthKbps === 'number') ul = caps.uplinkBandwidthKbps;
      if (typeof caps.signalStrength === 'number') sig = caps.signalStrength;
    } catch (_) {}
    return {
      connected: connected,
      network_type: type,
      download_bandwidth: dl,
      upload_bandwidth: ul,
      signal_strength: sig,
    };
  }

  private addAppLifecycleBreadcrumb(state: string): void {
    const bc = new Breadcrumb();
    bc.timestamp = new Date().toISOString();
    bc.message = 'App lifecycle changed';
    bc.category = 'app.lifecycle';
    bc.level = SentryLevel.Info;
    bc.type = 'navigation';
    const rec: Record<string, string> = {};
    rec['state'] = state;
    bc.data = rec;
    this.store.add(bc);
  }
}
