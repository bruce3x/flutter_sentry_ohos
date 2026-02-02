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

#ifndef SENTRY_REPLAY_ENCODER_H
#define SENTRY_REPLAY_ENCODER_H

#include <native_window/external_window.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>
#include <vector>

struct CodecContext;
struct OutputBufferInfo;
struct InputBufferInfo;
struct OH_AVBuffer;
struct OH_AVMuxer;
struct OH_AVCodec;
struct OH_AVFormat;
struct NativePixelMap;

// 编码输入参数结构体，用于减少函数参数个数
// 编码输入参数结构体，用于减少 Encode 函数参数个数
struct EncodeInputParams {
    const void *rgba = nullptr;
    size_t size = 0;
    int64_t timestampMs = 0;
    int32_t inputStride = 0;
    int32_t inputWidth = 0;
    int32_t inputHeight = 0;
};

// 准备并推送输入数据参数结构体
struct PrepareInputParams {
    const uint8_t *rgba = nullptr;
    size_t size = 0;
    int32_t inputStride = 0;
    int32_t inputWidth = 0;
    int32_t inputHeight = 0;
    uint32_t index = 0;
    OH_AVBuffer *buffer = nullptr;
    int64_t ptsUs = 0;
};

// RGBA转NV12转换参数结构体
struct ConvertParams {
    const uint8_t *rgba = nullptr;
    size_t size = 0;
    uint8_t *dest = nullptr;
    int32_t inputStride = 0;
    int32_t inputWidth = 0;
    int32_t inputHeight = 0;
};

class ReplayEncoder {
public:
    static ReplayEncoder &Instance();

    bool Init(int32_t fd, int32_t width, int32_t height, int32_t fps, const std::string &mimeType);
    bool Encode(const EncodeInputParams &params);
    // Use void* to avoid NativePixelMap type definition issues across TUs
    bool EncodePixelMap(void *pixelMap, int64_t timestampMs);

    // Returns the input surface (OHNativeWindow*) for the encoder.
    // Caller does NOT own the returned pointer (it belongs to the encoder).
    void *GetInputWindow();

    void Finalize();

private:
    ReplayEncoder();
    ~ReplayEncoder();
    ReplayEncoder(const ReplayEncoder &) = delete;
    ReplayEncoder &operator=(const ReplayEncoder &) = delete;

    struct CodecContext;

    void ResetState();
    void DrainOutputLoop();
    void ApplyBackgroundPriority();
    bool ConvertRgbaToNv12(const ConvertParams &params);
    void HandleCodecError(int32_t errorCode);
    void HandleFormatChange();

    // Init() 辅助函数
    bool ValidateInitParams(int32_t fd, int32_t width, int32_t height, int32_t fps);
    void CalculateAlignedDimensions(int32_t width, int32_t height);
    void CalculateBufferSizes();
    bool CreateMuxer(int32_t fd);
    bool CreateEncoder(const std::string &mimeTypeCopy);
    bool ConfigureEncoder(int64_t bitrate);
    bool StartEncoderAndMuxer();

    // Encode() 辅助函数
    bool ValidateEncodeInput(const EncodeInputParams &params, int32_t &realWidth,
                             int32_t &realHeight, size_t &strideBytes);
    bool AcquireInputBuffer(InputBufferInfo &bufferInfo, int64_t &waitTimeUs);
    int64_t CalculatePts(int64_t timestampMs);
    bool SubmitEncodedFrame(const InputBufferInfo &bufferInfo, int64_t ptsUs);
    void LogEncodePerformance(int64_t waitTimeUs, int64_t convertTimeUs, int64_t totalTimeUs);
    bool WaitForInputBuffer(uint32_t &index, OH_AVBuffer *&buffer);
    bool PrepareAndPushInputData(const PrepareInputParams &params);

    // ConvertRgbaToNv12() 辅助函数
    void ProcessUVBlock(const uint8_t *srcRow0, const uint8_t *srcRow1, int32_t x,
                        int32_t copyWidth, uint8_t *uvDst);

    // DrainOutputLoop() 辅助函数
    bool ProcessSingleOutputBuffer(const OutputBufferInfo &info);

    // Finalize() 辅助函数
    void SignalEndOfStream();
    void WaitForDrainThread();
    void StopEncoderResources();
    void StopMuxerResources();

    // ResetState() 辅助函数
    void ReleaseEncoder();
    void ReleaseMuxer();

    static void OnCodecError(struct OH_AVCodec *codec, int32_t errorCode, void *userData);
    static void OnCodecFormatChange(struct OH_AVCodec *codec, struct OH_AVFormat *format,
                                    void *userData);
    static void OnNeedInputBuffer(struct OH_AVCodec *codec, uint32_t index,
                                  struct OH_AVBuffer *buffer, void *userData);
    static void OnNewOutputBuffer(struct OH_AVCodec *codec, uint32_t index,
                                  struct OH_AVBuffer *buffer, void *userData);

private:
    bool ready_ = false;
    int32_t duplicatedFd_ = -1;
    int32_t width_ = 0;
    int32_t height_ = 0;
    int32_t fps_ = 0;
    std::string mimeType_;

    OH_AVMuxer *muxer_ = nullptr;
    int32_t videoTrackId_ = -1;
    bool muxerStarted_ = false;

    OH_AVCodec *videoEncoder_ = nullptr;
    bool encoderStarted_ = false;
    OHNativeWindow *nativeWindow_ = nullptr;

    std::unique_ptr<CodecContext> context_;
    std::thread drainThread_;
    std::atomic<bool> stopRequested_{false};

    std::vector<uint8_t> nv12Buffer_;
    size_t expectedFrameSize_ = 0;
    uint32_t yStride_ = 0;
    uint32_t uvStride_ = 0;
    size_t yPlaneSize_ = 0;
    size_t uvPlaneSize_ = 0;
    bool firstFrame_ = true;
    uint64_t frameCount_ = 0;
    uint64_t writtenSamples_ = 0;
    int64_t lastPtsUs_ = 0;
    int64_t basePtsUs_ = 0;
    bool hasBasePts_ = false;
    int64_t frameDurationUs_ = 0;
};

#endif  // SENTRY_REPLAY_ENCODER_H
