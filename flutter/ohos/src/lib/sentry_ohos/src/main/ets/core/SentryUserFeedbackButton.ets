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

@Component
export struct SentryUserFeedbackButton {
  @Prop text: string = 'Send Feedback'
  @Prop eventId?: string

  private async submit(): Promise<void> {
    const idFromProp = this.eventId && this.eventId.length > 0 ? this.eventId : undefined
    const last = Sentry.getLastEventId()
    const useId = idFromProp ? idFromProp : (last ? last : '')
    if (useId.length === 0) {
      console.warn('[Sentry] No eventId available for UserFeedback')
      return
    }
    const uf = new UserFeedback(useId)
    try { await Sentry.captureUserFeedback(uf) } catch (_) {}
  }

  build() {
    Button(this.text)
      .onClick(() => { this.submit() })
      .type(ButtonType.Capsule)
      .backgroundColor('#5C6BC0')
      .fontColor(Color.White)
      .fontSize(16)
      .padding(12)
  }
}


