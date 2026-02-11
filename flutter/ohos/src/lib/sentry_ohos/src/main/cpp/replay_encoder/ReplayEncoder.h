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

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>
#include <vector>
#include <native_window/external_window.h>

struct CodecContext;
struct OutputBufferInfo;
struct InputBufferInfo;
struct OH_AVBuffer;
struct OH_AVMuxer;
struct OH_AVCodec;
struct OH_AVFormat;
struct NativePixelMap;

enum class PixelFormat : int32_t {
    UNKNOWN = 0,
    RGBA8888 = 1,
    BGRA8888 = 2,
    RGB565 = 3,
    ARGB8888 = 4,
    RGB888 = 5,
};

struct EncodeInputInfo {
    int32_t stride = 0;
    int32_t width = 0;
    int32_t height = 0;
    int32_t pixelFormat = 1;
};

struct Nv12ConvertInput {
    const uint8_t *rgba = nullptr;
    uint8_t *dest = nullptr;
    size_t srcStride = 0;
    int32_t copyWidth = 0;
    int32_t copyHeight = 0;
    PixelFormat format = PixelFormat::RGBA8888;
};

class ReplayEncoder {
public:
    static ReplayEncoder &Instance();

    bool Init(int32_t fd, int32_t width,
              int32_t height, int32_t fps,
              const std::string &mimeType);
    bool Encode(const void *rgba, size_t size,
                int64_t timestampMs,
                const EncodeInputInfo &input = {});
    bool EncodePixelMap(void *pixelMap,
                        int64_t timestampMs);
    void *GetInputWindow();
    void Finalize();

private:
    ReplayEncoder();
    ~ReplayEncoder();
    ReplayEncoder(const ReplayEncoder &) = delete;
    ReplayEncoder &operator=(const ReplayEncoder &) = delete;

    struct CodecContext;

    void ResetState();
    void CleanupResources();
    void ReleaseEncoder();
    void ReleaseMuxer();
    void ResetMemberVariables();

    bool SetupResolution(int32_t width, int32_t height);
    void CalculateNv12Layout();
    bool CreateMuxerTrack(int64_t bitrate);
    bool ConfigureEncoder(int64_t bitrate);
    bool RegisterAndStartEncoder();
    int64_t CalculateBitrate() const;
    bool StartMuxerAndDrainThread();

    bool InitValidateParams(int32_t fd, int32_t width,
                            int32_t height, int32_t fps);
    bool InitSetupFdAndResolution(
        int32_t fd, int32_t width, int32_t height,
        int32_t fps, const std::string &mimeType);
    bool InitCreateComponents(int64_t bitrate);

    bool AcquireInputBuffer(uint32_t &index,
                            struct OH_AVBuffer *&buf);
    uint8_t *PrepareInputBuffer(
        struct OH_AVBuffer *buffer);
    bool SubmitInputBuffer(struct OH_AVBuffer *buffer,
                           uint32_t bufIndex,
                           int64_t ptsUs);
    int64_t ComputePresentationTime(
        int64_t timestampMs);
    void LogEncodePerformance(int64_t waitUs,
                              int64_t convertUs,
                              int64_t pushUs,
                              int64_t totalUs);

    void SignalEndOfStream();
    void StopEncoder();
    void StopMuxer();
    void WaitForEos();
    void StopDrainThread();

    void DrainOutputLoop();
    void DrainMainLoop();
    void DrainRemainingBuffers();
    void ProcessOutputInfo(
        const struct OutputBufferInfo &info);
    void ApplyBackgroundPriority();
    bool AcquireAndConvertFrame(
        const Nv12ConvertInput &cvt,
        int64_t ptsUs);
    bool ConvertRgbaToNv12(
        const Nv12ConvertInput &input);
    void HandleCodecError(int32_t errorCode);
    void HandleFormatChange();

    static PixelFormat ToPixelFormat(int32_t value);

    static void OnCodecError(
        struct OH_AVCodec *codec,
        int32_t errorCode, void *userData);
    static void OnCodecFormatChange(
        struct OH_AVCodec *codec,
        struct OH_AVFormat *format,
        void *userData);
    static void OnNeedInputBuffer(
        struct OH_AVCodec *codec, uint32_t index,
        struct OH_AVBuffer *buffer,
        void *userData);
    static void OnNewOutputBuffer(
        struct OH_AVCodec *codec, uint32_t index,
        struct OH_AVBuffer *buffer,
        void *userData);

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
    std::atomic<bool> stopRequested_ {false};

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

#endif // SENTRY_REPLAY_ENCODER_H
