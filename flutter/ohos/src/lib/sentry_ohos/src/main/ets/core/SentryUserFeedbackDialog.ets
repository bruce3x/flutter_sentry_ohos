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

import { Sentry } from '../sentry/Sentry'
import { UserFeedback } from '../sentry/UserFeedback'

// 用法：openSentryUserFeedbackDialog(optionalEventId)
export function openSentryUserFeedbackDialog(eventId?: string): CustomDialogController {
  let ctrl: CustomDialogController;
  ctrl = new CustomDialogController({
    builder: () => new SentryUserFeedbackDialog({ eventId, onSubmitted: (_ok: boolean) => { try { ctrl.close() } catch (_) {} } })
  });
  try { ctrl.open() } catch (_) {}
  return ctrl;
}

@CustomDialog
export struct SentryUserFeedbackDialog {
  controller?: CustomDialogController
  eventId?: string
  onSubmitted?: (ok: boolean) => void

  @State private name: string = ''
  @State private email: string = ''
  @State private comments: string = ''

  private async submit(): Promise<void> {
    const idFromProp = this.eventId && this.eventId.length > 0 ? this.eventId : undefined
    const last = Sentry.getLastEventId()
    const useId = idFromProp ? idFromProp : (last ? last : '')
    if (useId.length === 0) {
      console.warn('[Sentry] No eventId available for UserFeedback')
      if (this.onSubmitted) this.onSubmitted(false)
      return
    }
    const uf = new UserFeedback(useId)
    uf.name = this.name
    uf.email = this.email
    uf.comments = this.comments
    try { await Sentry.captureUserFeedback(uf) } catch (_) {}
    if (this.onSubmitted) this.onSubmitted(true)
  }

  build() {
    Column() {
      Text('User Feedback').fontSize(20).fontWeight(FontWeight.Medium).margin({ bottom: 12 })

      Column() {
        Text('Name').fontSize(14).margin({ bottom: 6 })
        TextInput({ placeholder: 'Your name' })
          .width('100%')
          .onChange((v: string) => { this.name = v })
      }.margin({ bottom: 10 })

      Column() {
        Text('Email').fontSize(14).margin({ bottom: 6 })
        TextInput({ placeholder: 'name@example.com' })
          .width('100%')
          .onChange((v: string) => { this.email = v })
      }.margin({ bottom: 10 })

      Column() {
        Text('Comments').fontSize(14).margin({ bottom: 6 })
        TextInput({ placeholder: 'What happened?' })
          .width('100%')
          .height(96)
          .type(InputType.Normal)
          .onChange((v: string) => { this.comments = v })
      }.margin({ bottom: 14 })

      Row() {
        Button('Cancel')
          .type(ButtonType.Normal)
          .onClick(() => { try { this.controller?.close() } catch (_) {} })
        Blank()
        Button('Submit')
          .type(ButtonType.Capsule)
          .backgroundColor('#43A047')
          .fontColor(Color.White)
          .onClick(() => { this.submit() })
      }
    }
    .width('86%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(10)
  }
}


