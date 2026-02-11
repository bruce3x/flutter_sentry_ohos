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
import { SentryOhos, updateReplayContext, InternalSentrySdk } from 'sentry_flutter/src/lib/sentry_ohos/Index';
import window from '@ohos.window';
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

  private static readonly REPLAY_LOG_TAG: string = 'REPLAY_TAG EntryAbility';
  private static readonly UI_CONTEXT_STORAGE_KEY: string = 'SentryReplayUiContext';
  private static readonly UI_CONTEXT_RETRY_LIMIT: number = 6;
  private static readonly UI_CONTEXT_RETRY_BASE_DELAY_MS: number = 150;
  private nativeChannel: MethodChannel | null = null;
  private outboxPath: string = "";
  private SENTRY_DSN: string = 'https://377c5438bf2f705c43b49e8a5d99a0af@o4510441206251520.ingest.us.sentry.io/4510441208741888';


  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    super.onCreate(want, launchParam);
    this.addEventHub();
    // Optimize startup: Move replay context refresh and NDK init to next tick to avoid blocking onCreate
    setTimeout(() => {
      this.initNdk();
      this.refreshReplayContext('onCreate', 0);
      this.startOutboxFlushing();
    }, 0);
  }

  private refreshReplayContext(source: string, delayMs: number = 0): void {
    try {
      SentryOhos.setBaseContext(this.context);
    } catch (err) {
      console.error(`${EntryAbility.REPLAY_LOG_TAG} setBaseContext失败(${source}): ${JSON.stringify(err)}`);
    }
    try {
      this.logContextDetails(source);
    } catch (_) {}
    setTimeout(() => {
      try {
        updateReplayContext(this.context);
      } catch (updateErr) {
        console.error(`${EntryAbility.REPLAY_LOG_TAG} 失败(${source}): ${JSON.stringify(updateErr)}`);
      }
    }, delayMs);
  }

  private logContextDetails(source: string): void {
    try {
      const ctx = this.context as Object;
      let ctorName = 'undefined';
      if (ctx && (ctx as Object).constructor) {
        ctorName = ((ctx as Object).constructor as Function).name;
      }
      let abilityType = 'unknown';
      let abilityTypeKind = 'unknown';
      let typeValue: Object | undefined = undefined;
      try {
        const ctxAny = ctx as Record<string, Object>;
        const abilityInfo = ctxAny ? ctxAny['abilityInfo'] as Record<string, Object> : undefined;
        typeValue = abilityInfo ? abilityInfo['type'] : undefined;
        if (typeValue !== undefined) {
          abilityType = String(typeValue);
          abilityTypeKind = typeof typeValue;
        }
      } catch (_) {}
      let isUiAbility = false;
      if (typeof typeValue === 'number') {
        isUiAbility = typeValue === 1;
      } else if (typeof typeValue === 'string') {
        const normalized = typeValue.trim().toLowerCase();
        isUiAbility = normalized === 'uiability' || normalized === 'ui' || normalized === '1';
      }
      if (!isUiAbility && (ctorName === 'UIAbilityContext' || ctorName === 'AbilityContext')) {
        isUiAbility = true;
      }
      let hasWindowStage = false;
      try {
        const ctxAny = ctx as Record<string, Object>;
        const stage = ctxAny ? ctxAny['windowStage'] : undefined;
        hasWindowStage = stage !== undefined && stage !== null;
        if (!isUiAbility && hasWindowStage) {
          isUiAbility = true;
        }
      } catch (_) {}
      console.info(`${EntryAbility.REPLAY_LOG_TAG} contextCheck(${source}) ctor=${ctorName}, abilityType=${abilityType}, typeKind=${abilityTypeKind}, hasWindowStage=${String(hasWindowStage)}, isUIAbility=${String(isUiAbility)}`);
    } catch (err) {
      console.error(`${EntryAbility.REPLAY_LOG_TAG} contextCheck(${source}) 记录失败: ${String(err)}`);
    }
  }

  private uiContextStored: boolean = false;
  private uiContextRetryTimers: Array<number> = [];

  onWindowStageCreate(windowStage: window.WindowStage): void {
    super.onWindowStageCreate(windowStage);
    this.cancelUiContextRetries();
    this.uiContextStored = false;
    this.refreshReplayContext('onWindowStageCreate-0ms', 0);
    this.refreshReplayContext('onWindowStageCreate-200ms', 200);
    this.captureUiContext(windowStage, 'onWindowStageCreate');
    try {
      windowStage.on('windowStageEvent', (event: window.WindowStageEventType) => {
        if (event === window.WindowStageEventType.ACTIVE) {
          this.captureUiContext(windowStage, 'windowStageEvent');
          this.refreshReplayContext('windowStage.active', 0);
        }
      });
    } catch (err) {
      console.error(`${EntryAbility.REPLAY_LOG_TAG} windowStageEvent 注册失败: ${JSON.stringify(err)}`);
    }
  }

  private captureUiContext(windowStage: window.WindowStage, reason: string, attempt: number = 0): void {
    if (this.uiContextStored && attempt === 0) {
      return;
    }
    try {
      const mainWindow = windowStage.getMainWindowSync();
      const uiContext = mainWindow ? mainWindow.getUIContext() : undefined;
      if (uiContext) {
        AppStorage.setOrCreate(EntryAbility.UI_CONTEXT_STORAGE_KEY, uiContext);
        this.uiContextStored = true;
        this.cancelUiContextRetries();
        console.info(`${EntryAbility.REPLAY_LOG_TAG} 存储UIContext成功(${reason}#${attempt}) key=${EntryAbility.UI_CONTEXT_STORAGE_KEY}`);
        return;
      }
      this.handleUiContextRetry(windowStage, reason, attempt, '空返回');
    } catch (err) {
      const code = this.extractErrorCode(err);
      if (code === 1300002) {
        this.handleUiContextRetry(windowStage, reason, attempt, `code=${code}`);
        return;
      }
      console.error(`${EntryAbility.REPLAY_LOG_TAG} getUIContext(${reason}#${attempt}) 失败: ${JSON.stringify(err)}`);
    }
  }

  private handleUiContextRetry(windowStage: window.WindowStage, reason: string, attempt: number, detail: string): void {
    if (attempt + 1 >= EntryAbility.UI_CONTEXT_RETRY_LIMIT) {
      console.warn(`${EntryAbility.REPLAY_LOG_TAG} getUIContext(${reason}#${attempt}) 放弃重试, detail=${detail}`);
      return;
    }
    const nextAttempt = attempt + 1;
    const delay = EntryAbility.UI_CONTEXT_RETRY_BASE_DELAY_MS * (nextAttempt + 1);
    console.warn(`${EntryAbility.REPLAY_LOG_TAG} getUIContext(${reason}#${attempt}) 未就绪(${detail}), ${delay}ms 后重试(${nextAttempt})`);
    let timerId = 0;
    const timerHandle = setTimeout(() => {
      const index = this.uiContextRetryTimers.indexOf(timerId);
      if (index >= 0) {
        this.uiContextRetryTimers.splice(index, 1);
      }
      this.captureUiContext(windowStage, reason, nextAttempt);
    }, delay);
    timerId = typeof timerHandle === 'number' ? timerHandle : Number(timerHandle);
    this.uiContextRetryTimers.push(timerId);
  }

  private cancelUiContextRetries(): void {
    for (let i = 0; i < this.uiContextRetryTimers.length; i++) {
      const timerId = this.uiContextRetryTimers[i];
      clearTimeout(timerId);
    }
    this.uiContextRetryTimers = [];
  }

  private extractErrorCode(err: Object | undefined): number | undefined {
    if (!err) {
      return undefined;
    }
    const record = err as Record<string, Object>;
    const codeCandidate = record['code'];
    if (typeof codeCandidate === 'number') {
      return codeCandidate;
    }
    return undefined;
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
                console.error(`${EntryAbility.REPLAY_LOG_TAG} ERROR beatAnr not available! SentryOhos=${typeof SentryOhos}, beatAnr=${SentryOhos ? typeof SentryOhos.beatAnr : 'N/A'}`);
              }
            } catch (err) {
              console.error(`${EntryAbility.REPLAY_LOG_TAG} ERROR Failed to beat ANR before blocking: ${err}`);
            }
            // 兜底：在阻塞前预先生成并缓存一条 ANR 事件，避免阻塞期间被系统杀死
            try {

              SentryOhos.forceAnrEvent(10000);
            } catch (e) {
              console.error(`${EntryAbility.REPLAY_LOG_TAG} PREEMPTIVE forceAnrEvent failed: ${e}`);
            }
            // 记录阻塞开始时间
            const blockStartMs = Date.now();

            // 阻塞主线程


            try {
              self.anr();

            } catch (err) {
              console.error(`${EntryAbility.REPLAY_LOG_TAG} ERROR during self.anr() call: ${err}`);
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
                  console.error(`${EntryAbility.REPLAY_LOG_TAG} ERROR during triggerAnrCheck() call: ${err}`);
                }
              } else {
                console.error(`${EntryAbility.REPLAY_LOG_TAG} ERROR triggerAnrCheck not available! SentryOhos=${typeof SentryOhos}, triggerAnrCheck=${typeof (SentryOhos && SentryOhos.triggerAnrCheck)}`);
              }
            } catch (err) {
              console.error(`${EntryAbility.REPLAY_LOG_TAG} FATAL ERROR in ANR check trigger block: ${err}`);
            }

          } catch (err) {
            console.error(`${EntryAbility.REPLAY_LOG_TAG} FATAL ERROR: ANR blocking failed: ${err}`);
          }
          result.success('');
        } else if (call.method == 'capture') {
          try {
            Sentry.captureMessage('Trigger a local capture message');
          } catch (err) {
            console.error(`${EntryAbility.REPLAY_LOG_TAG} onMethodCall capture_message`);
          }
          result.success('');
        } else if (call.method == 'crash') {
          emitter.emit('crash');
          result.success('');
        } else if (call.method == 'platform_exception') {
          emitter.emit('platform_exception');
        } else if (call.method == 'cpp_capture_message') {
          NdkSample.message();
          result.success('');
        } else {
          result.notImplemented()
        }
      }
    })
  }

  // ndk初始化方法
  private initNdk(): boolean {
    try {
      this.outboxPath = this.setupOutboxFolder();
      console.info(`${EntryAbility.REPLAY_LOG_TAG} NDK init: outboxPath=${this.outboxPath}`);
      
      // 创建 NdkOptions 实例
      const options : NdkOptions = {
        dsn: this.SENTRY_DSN,
        outboxPath: this.outboxPath + '/', // Restore trailing slash to match 3.22 config
        release: "1.1.x",
        environment: "development",
        dist: 'true',
        isDebug: true,
        maxBreadcrumbs: 100,
        sdkName: "sentry-ohos",
        tracesSampleRate: 1,
        ndkHandlerStrategy: NdkHandlerStrategy.SENTRY_HANDLER_STRATEGY_DEFAULT
      };
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
      console.error(`${EntryAbility.REPLAY_LOG_TAG} Failed to setup outbox folder: ${err.message}`);
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
      console.error(`${EntryAbility.REPLAY_LOG_TAG} ERROR in busy wait: ${err}`);
    }
  }

  private startOutboxFlushing(): void {
    // 立即执行一次
    this.flushOutbox();
    // 每 5 秒轮询一次 outbox
    setInterval(() => {
      this.flushOutbox();
    }, 5000);
  }

  private async flushOutbox(): Promise<void> {
    try {
      const outboxDir = this.outboxPath;
      if (!outboxDir || !fs.accessSync(outboxDir)) {
         console.warn(`${EntryAbility.REPLAY_LOG_TAG} outboxDir does not exist or not set: ${outboxDir}`);
         return;
      }
      
      const filenames = fs.listFileSync(outboxDir);
      console.info(`${EntryAbility.REPLAY_LOG_TAG} Checking outbox ${outboxDir}: found ${filenames.length} files`);
      
      if (filenames.length === 0) {
        // Debug: list parent dir to see if we missed it
        try {
           const parent = outboxDir.substring(0, outboxDir.lastIndexOf('/'));
           const parentFiles = fs.listFileSync(parent);
           console.info(`${EntryAbility.REPLAY_LOG_TAG} Parent dir ${parent} listing: ${JSON.stringify(parentFiles)}`);
        } catch (_) {}
      } else {
        // Log all filenames for debugging
        console.info(`${EntryAbility.REPLAY_LOG_TAG} Outbox files: ${JSON.stringify(filenames)}`);
      }
      
      // Check if .sentry-native exists and list it
      if (filenames.includes('.sentry-native')) {
         try {
            const innerDir = `${outboxDir}/.sentry-native`;
            const innerFiles = fs.listFileSync(innerDir);
            console.info(`${EntryAbility.REPLAY_LOG_TAG} .sentry-native listing: ${JSON.stringify(innerFiles)}`);
         } catch (e) {
            console.warn(`${EntryAbility.REPLAY_LOG_TAG} Failed to list .sentry-native: ${e}`);
         }
      }

      for (const filename of filenames) {
        if (filename === '.' || filename === '..') continue;
        const filePath = `${outboxDir}/${filename}`;
        
        try {
          const stat = fs.statSync(filePath);
          
          if (stat.isFile()) {
            // 读取文件内容
            const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
            const size = stat.size;
            if (size > 0) {
              const buf = new ArrayBuffer(size);
              fs.readSync(file.fd, buf);
              const bytes = new Uint8Array(buf);
              fs.closeSync(file);
              
              // 发送 Envelope (startNewSession=false)
              const sentId = await InternalSentrySdk.captureEnvelopeBytes(bytes, false);
              
              const isSent = sentId && sentId.toString() !== '00000000000000000000000000000000';
              if (isSent) {
                 try { fs.unlinkSync(filePath); } catch (_) {}
              } else {
                 console.warn(`${EntryAbility.REPLAY_LOG_TAG} Flushed failed (transport not ready?): ${filename}. Retrying later.`);
                 // Do NOT delete, retry later
              }
            } else {
              fs.closeSync(file);
              try { fs.unlinkSync(filePath); } catch (_) {}
            }
          }
        } catch (e) {
          console.error(`${EntryAbility.REPLAY_LOG_TAG} Failed to process outbox file ${filename}: ${e}`);
          // 尝试删除损坏文件
          try { fs.unlinkSync(filePath); } catch (_) {}
        }
      }
    } catch (e) {
      // outbox 可能不存在或无法访问，属于正常情况
    }
  }
}
