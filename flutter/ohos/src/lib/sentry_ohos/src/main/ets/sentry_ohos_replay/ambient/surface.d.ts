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

/*
 * Minimal ambient typings for @ohos.graphics.surface used by ArkTsVideoEncoder.
 * Only declare the subset we actually use, to satisfy strict typing in ETS.
 * Runtime implementation is provided by the system module.
 */

declare module '@ohos.graphics.surface' {
  import type image from '@ohos.multimedia.image';
  import type drawing from '@ohos.graphics.drawing';

  /** Create a Surface instance from a surface id (returned by AVRecorder.getInputSurface). */
  export function createSurfaceFromId(surfaceId: string): Promise<Surface>;

  /** Surface frame used to draw one frame and commit to encoder. */
  export interface SurfaceFrame {
    /** Returns a drawing canvas to render into the frame. */
    getCanvas(): drawing.Canvas;
  }

  /** Surface provides frame request and flush for producer side. */
  export interface Surface {
    /** Request a frame with desired size for drawing. */
    requestFrame(width: number, height: number): Promise<SurfaceFrame>;
    /** Flush the drawn frame to the consumer (encoder). */
    flushFrame(frame: SurfaceFrame): Promise<void>;
  }
}




