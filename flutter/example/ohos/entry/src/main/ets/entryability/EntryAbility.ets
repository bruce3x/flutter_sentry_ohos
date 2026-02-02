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

import { FlutterAbility, FlutterEngine, MethodCall, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { Sentry } from 'sentry_flutter/src/lib/sentry_ohos/Index';
import { SentryOhos } from 'sentry_flutter/src/lib/sentry_ohos/Index';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';
import worker from '@ohos.worker';

import fs from '@ohos.file.fs';
import { NdkHandlerStrategy, NdkOptions, SentryNdk } from '@ohos/sentry_native';
import NdkSample from 'libentry.so';
import prompt from '@ohos.promptAction';
import emitter from '@ohos.events.emitter';


export default class EntryAbility extends FlutterAbility {

  private nativeChannel: MethodChannel | null = null;
  private outboxPath: string = "";
  private SENTRY_DSN: string = 'https://b6a6002ada31addaced3c0cc208e3df6@o4509908127842304.ingest.us.sentry.io/4509908136558592';


  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    super.onCreate(want, launchParam);
    // Optimize startup: Move initNdk to next tick to avoid blocking onCreate
    setTimeout(() => {
      this.initNdk();
    }, 0);
    this.addEventHub();
  }

  addEventHub() {

    emitter.on('throw',(_) => {
      setTimeout(() => {
        throw new Error("Catch this exception thrown from HarmonyOS async task!");
      }, 0);
    })

    emitter.on('crash',(_) => {
      NdkSample.crash();
    })

    emitter.on('platform_exception',(_) => {
      throw new Error('Catch this platform exception!');
    })
  }

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)

    GeneratedPluginRegistrant.registerWith(flutterEngine)

    this.nativeChannel = new MethodChannel(flutterEngine.dartExecutor.getBinaryMessenger(), "example.flutter.sentry.io");

    const self = this; // 保存 EntryAbility 实例引用
    this.nativeChannel.setMethodCallHandler({

      onMethodCall(call: MethodCall, result: MethodResult): void {
        // 扩展里面debug必填
        console.log(`worker_check onMethodCall= ${worker.ThreadWorker.name}`);

        Sentry.setExtra('debug', true);
        if (call.method == 'throw') {
          emitter.emit('throw' );
          result.success('');
        } else if (call.method == 'anr') {
          // 同步阻塞 ARKUI 主线程 ~10s 以触发 ANR 检测
          try {
            // 在阻塞前先记录心跳，这样阻塞后检查时就能检测到时间差
            try {
              if (SentryOhos && typeof SentryOhos.beatAnr === 'function') {
                const beatBeforeMs = Date.now();
                SentryOhos.beatAnr();
                const beatAfterMs = Date.now();
              } else {
                console.error(`[Sentry] EntryAbility ERROR: SentryOhos.beatAnr not available! SentryOhos=${typeof SentryOhos}, beatAnr=${SentryOhos ? typeof SentryOhos.beatAnr : 'N/A'}`);
              }
            } catch (err) {
              console.error(`[Sentry] EntryAbility ERROR: Failed to beat ANR before blocking: ${err}`);
            }
            // 兜底：在阻塞前预先生成并缓存一条 ANR 事件，避免阻塞期间被系统杀死
            try {
              SentryOhos.forceAnrEvent(10000);
            } catch (e) {
              console.error(`[Sentry] EntryAbility PREEMPTIVE forceAnrEvent failed: ${e}`);
            }
            // 记录阻塞开始时间
            const blockStartMs = Date.now();

            // 阻塞主线程
            try {
              self.anr();
            } catch (err) {
              console.error(`[Sentry] EntryAbility ERROR during self.anr() call: ${err}`);
              throw err instanceof Error ? err : new Error(String(err));
            }
            const blockEndMs = Date.now();
            const blockedDuration = blockEndMs - blockStartMs;

            // 阻塞后立即触发 ANR 检测（因为阻塞期间定时器回调无法执行）
            // 重要：即使应用即将崩溃，也要尽快触发检查
            try {
              if (SentryOhos && typeof SentryOhos.triggerAnrCheck === 'function') {

                try {
                  const triggerStartMs = Date.now();
                  // 立即同步调用，不等待
                  SentryOhos.triggerAnrCheck();
                  const triggerEndMs = Date.now();

                } catch (err) {
                  console.error(`[Sentry] EntryAbility ERROR during triggerAnrCheck() call: ${err}`);
                }
              } else {
                console.error(`[Sentry] EntryAbility ERROR: SentryOhos.triggerAnrCheck not available! SentryOhos=${typeof SentryOhos}, triggerAnrCheck=${typeof (SentryOhos && SentryOhos.triggerAnrCheck)}`);
              }
            } catch (err) {
              console.error(`[Sentry] EntryAbility FATAL ERROR in ANR check trigger block: ${err}`);
            }

          } catch (err) {
            console.error(`[Sentry] EntryAbility FATAL ERROR: ANR blocking failed: ${err}`);
          }
          result.success('');
        } else if (call.method == 'capture') {
          try {
            Sentry.captureMessage('Trigger a local capture message');
          } catch (err) {
            console.error(`[EntryAbility] onMethodCall capture_message`);
          }
          result.success('');
        } else if (call.method == 'crash') {
          emitter.emit('crash');
          result.success('');
        } else if (call.method == 'cpp_capture_message') {
          NdkSample.message();
          result.success('');
        } else if (call.method == 'platform_exception') {
          emitter.emit('platform_exception');
        } else {
          result.notImplemented()
        }
      }
    })
  }

  // ndk初始化方法
  private initNdk(): boolean {

    try {
      this.outboxPath = this.setupOutboxFolder() + '/';
      // 创建 NdkOptions 实例
      const options : NdkOptions = {
        dsn: this.SENTRY_DSN,
        outboxPath: this.outboxPath,
        release: "1.1.x",
        environment: "development",
        dist: 'true',
        isDebug: true,
        maxBreadcrumbs: 100,
        sdkName: "sentry-ohos",
        tracesSampleRate: 1,
        ndkHandlerStrategy: NdkHandlerStrategy.SENTRY_HANDLER_STRATEGY_DEFAULT
      };
      console.debug("Type of options:", typeof options)
      // 初始化 Sentry NDK
      SentryNdk.init(options);
      console.info("Sentry NDK initialized successfully");
      return true;
    } catch (err) {
      console.error(`Failed to initialize Sentry NDK: ${err.message}`);
      return false;
    }
  }

  // 设置输出文件夹
  private setupOutboxFolder(): string {
    try {
      // 获取应用文件目录
      const filesDir = this.context.filesDir;
      const outboxDir = `${filesDir}/outbox`;

      // 检查目录是否存在
      let isExist = false;
      try {
        isExist = fs.accessSync(outboxDir);
      } catch (err) {
        if (err.code !== 2) { // 2 表示文件不存在
          console.error("error ocurr")
        }
      }

      if (isExist) {
        // 检查是否是文件
        const stat = fs.statSync(outboxDir);
        if (stat.isFile()) {
          // 删除文件
          fs.unlinkSync(outboxDir);
          // 创建目录
          fs.mkdirSync(outboxDir);
        }
      } else {
        // 创建目录
        fs.mkdirSync(outboxDir);
      }

      return outboxDir;
    } catch (err) {
      console.error(`Failed to setup outbox folder: ${err.message}`);
      throw new Error(`Failed to setup outbox folder: ${err.message}`);
    }
  }

  anr() {
    // 同步阻塞 ARKUI 主线程 ~10s 以触发 ANR 检测（与 Android 示例对齐）
    const sleepDurationInMillis: number = 10000;
    try {

      const start: number = Date.now();

      let iterations = 0;
      let lastLogTime = start;
      // Busy wait 直接阻塞 UI 线程，触发 ANR 检测阈值（通常 >= 5s）
      while (true) {
        const current = Date.now();
        const elapsed = current - start;

        // 每 100ms 记录一次进度（改为更频繁的日志）
        if (current - lastLogTime >= 100) {
          lastLogTime = current;
        }

        if (elapsed >= sleepDurationInMillis) {
          break;
        }

        iterations++;
        // 添加安全检查，防止无限循环
        if (iterations % 10000000 === 0) {

        }
      }
      const finalTime = Date.now();
      const finalElapsed = finalTime - start;

    } catch (err) {
      console.error(`[Sentry] EntryAbility ERROR in busy wait: ${err}`);
    }
  }
}
