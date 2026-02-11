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

#include "ReplayEncoder.h"

#include <algorithm>
#include <chrono>
#include <cerrno>
#include <cinttypes>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <mutex>
#include <pthread.h>
#include <queue>
#include <sched.h>
#include <unistd.h>

#include "hilog/log.h"
#include "multimedia/player_framework/native_avbuffer.h"
#include "multimedia/player_framework/native_avcodec_base.h"
#include "multimedia/player_framework/native_avcodec_videoencoder.h"
#include "multimedia/player_framework/native_averrors.h"
#include "multimedia/player_framework/native_avformat.h"
#include "multimedia/player_framework/native_avmuxer.h"
#include "multimedia/image_framework/image_pixel_map_napi.h"
#include "native_buffer/native_buffer.h"

namespace {
constexpr unsigned int REPLAY_LOG_DOMAIN = 0xD005760;
constexpr const char REPLAY_LOG_TAG[] = "ReplayEncoder";

#define REPLAY_LOG(level, fmt, ...) \
    OH_LOG_Print(LOG_APP, level, REPLAY_LOG_DOMAIN, \
                 REPLAY_LOG_TAG, fmt, ##__VA_ARGS__)

constexpr int32_t K_MIN_ENCODER_SIZE = 256;
constexpr int32_t K_RESOLUTION_ALIGNMENT = 16;
constexpr int32_t K_STRIDE_ALIGNMENT = 64;
constexpr int64_t K_MIN_BITRATE = 100000;
constexpr int32_t K_I_FRAME_INTERVAL = 1000;
constexpr int64_t K_FALLBACK_FRAME_DURATION_US = 1000;
constexpr int64_t K_MS_TO_US_MULTIPLIER = 1000;
constexpr int64_t K_US_PER_SECOND = 1000000LL;
constexpr int64_t K_BITRATE_NUMERATOR = 3;
constexpr int64_t K_BITRATE_DENOMINATOR = 4;

constexpr int32_t K_RGBA_BYTES_PER_PIXEL = 4;
constexpr int32_t K_MAX_BYTE_VALUE = 255;
constexpr int32_t K_UV_SUBSAMPLE = 2;
constexpr uint8_t K_UV_NEUTRAL = 128;

constexpr int K_BGRA_B_OFFSET = 0;
constexpr int K_BGRA_G_OFFSET = 1;
constexpr int K_BGRA_R_OFFSET = 2;

constexpr int K_ARGB_R_OFFSET = 1;
constexpr int K_ARGB_G_OFFSET = 2;
constexpr int K_ARGB_B_OFFSET = 3;

constexpr int K_RGBA_R_OFFSET = 0;
constexpr int K_RGBA_G_OFFSET = 1;
constexpr int K_RGBA_B_OFFSET = 2;

constexpr int32_t BT601_Y_R = 66;
constexpr int32_t BT601_Y_G = 129;
constexpr int32_t BT601_Y_B = 25;
constexpr int32_t BT601_Y_BIAS = 16;
constexpr int32_t BT601_U_R = -38;
constexpr int32_t BT601_U_G = -74;
constexpr int32_t BT601_U_B = 112;
constexpr int32_t BT601_V_R = 112;
constexpr int32_t BT601_V_G = -94;
constexpr int32_t BT601_V_B = -18;
constexpr int32_t BT601_UV_BIAS = 128;
constexpr int32_t BT601_ROUND = 128;
constexpr int32_t BT601_SHIFT = 8;

constexpr int64_t K_PERF_WAIT_THRESHOLD_US = 10000;
constexpr int64_t K_PERF_CONVERT_THRESHOLD_US = 50000;
constexpr int64_t K_PERF_PUSH_THRESHOLD_US = 5000;
constexpr int64_t K_PERF_TOTAL_THRESHOLD_US = 100000;
constexpr uint64_t K_PERF_LOG_INTERVAL = 20;
constexpr int64_t K_INPUT_BUFFER_TIMEOUT_MS = 500;
constexpr int64_t K_EOS_BUFFER_TIMEOUT_MS = 2000;
constexpr int32_t K_EOS_TIMEOUT_SECONDS = 5;

typedef int32_t (*OhPixelMapGetImageInfoFunc)(
    NativePixelMap *pixelMap,
    OHOS::Media::OhosPixelMapInfo *info);
typedef int32_t (*OhPixelMapAccessPixelsFunc)(
    NativePixelMap *pixelMap, void **pixels);
typedef int32_t (*OhPixelMapUnAccessPixelsFunc)(
    NativePixelMap *pixelMap);

static OhPixelMapGetImageInfoFunc g_getImageInfo =
    nullptr;
static OhPixelMapAccessPixelsFunc g_accessPixels =
    nullptr;
static OhPixelMapUnAccessPixelsFunc g_unAccessPixels =
    nullptr;

bool EnsurePixelMapFuncs()
{
    if (g_getImageInfo && g_accessPixels &&
        g_unAccessPixels) {
        return true;
    }
    void *handle =
        dlopen("libpixelmap_ndk.z.so", RTLD_LAZY);
    if (!handle) {
        handle =
            dlopen("libimage_ndk.z.so", RTLD_LAZY);
    }
    if (!handle) {
        REPLAY_LOG(LOG_ERROR,
            "EnsurePixelMapFuncs: failed to dlopen");
        return false;
    }
    g_getImageInfo =
        reinterpret_cast<OhPixelMapGetImageInfoFunc>(
            dlsym(handle, "OH_PixelMap_GetImageInfo"));
    g_accessPixels =
        reinterpret_cast<OhPixelMapAccessPixelsFunc>(
            dlsym(handle, "OH_PixelMap_AccessPixels"));
    g_unAccessPixels =
        reinterpret_cast<OhPixelMapUnAccessPixelsFunc>(
            dlsym(handle, "OH_PixelMap_UnAccessPixels"));
    if (!g_getImageInfo || !g_accessPixels ||
        !g_unAccessPixels) {
        REPLAY_LOG(LOG_ERROR,
            "EnsurePixelMapFuncs: dlsym failed");
        return false;
    }
    return true;
}

inline uint8_t ClampToByte(int value)
{
    return static_cast<uint8_t>(
        std::min(std::max(value, 0), K_MAX_BYTE_VALUE));
}

void ExtractRgb(
    const uint8_t *pixel, PixelFormat format,
    int &r, int &g, int &b)
{
    switch (format) {
        case PixelFormat::BGRA8888:
            b = pixel[K_BGRA_B_OFFSET];
            g = pixel[K_BGRA_G_OFFSET];
            r = pixel[K_BGRA_R_OFFSET];
            break;
        case PixelFormat::ARGB8888:
            r = pixel[K_ARGB_R_OFFSET];
            g = pixel[K_ARGB_G_OFFSET];
            b = pixel[K_ARGB_B_OFFSET];
            break;
        default:
            r = pixel[K_RGBA_R_OFFSET];
            g = pixel[K_RGBA_G_OFFSET];
            b = pixel[K_RGBA_B_OFFSET];
            break;
    }
}

struct RgbAccumulator {
    int rSum = 0;
    int gSum = 0;
    int bSum = 0;
    int count = 0;
};

struct RgbAverage {
    int r = 0;
    int g = 0;
    int b = 0;
};

struct PlaneInfo {
    uint8_t *data = nullptr;
    size_t stride = 0;
};

struct PlaneConvertInput {
    const uint8_t *rgba = nullptr;
    size_t srcStride = 0;
    int32_t copyWidth = 0;
    int32_t copyHeight = 0;
    PixelFormat format = PixelFormat::RGBA8888;
};

inline uint8_t RgbaToY(int r, int g, int b)
{
    return ClampToByte(
        ((BT601_Y_R * r + BT601_Y_G * g +
          BT601_Y_B * b + BT601_ROUND) >>
         BT601_SHIFT) + BT601_Y_BIAS);
}

inline void ComputeAndWriteUv(
    const RgbAverage &avg,
    uint8_t *uDst, uint8_t *vDst)
{
    int uVal =
        ((BT601_U_R * avg.r + BT601_U_G * avg.g +
          BT601_U_B * avg.b + BT601_ROUND) >>
         BT601_SHIFT) + BT601_UV_BIAS;
    int vVal =
        ((BT601_V_R * avg.r + BT601_V_G * avg.g +
          BT601_V_B * avg.b + BT601_ROUND) >>
         BT601_SHIFT) + BT601_UV_BIAS;
    *uDst = ClampToByte(uVal);
    *vDst = ClampToByte(vVal);
}

inline int64_t MicrosSince(
    std::chrono::steady_clock::time_point start)
{
    return std::chrono::duration_cast<
        std::chrono::microseconds>(
        std::chrono::steady_clock::now() -
        start).count();
}

inline size_t ComputeStride(
    int32_t inputStride, int32_t realWidth)
{
    return (inputStride > 0)
        ? static_cast<size_t>(inputStride)
        : (static_cast<size_t>(realWidth) *
           K_RGBA_BYTES_PER_PIXEL);
}

inline int32_t CeilByAspect(
    double minSize, double aspectRatio)
{
    double safeAR =
        (aspectRatio > 0.0) ? aspectRatio : 1.0;
    return static_cast<int32_t>(
        std::ceil(minSize / safeAR));
}

void AlignToMinSize(
    int32_t &targetW, int32_t &targetH,
    double aspectRatio)
{
    if (aspectRatio <= 0.0) {
        return;
    }
    double minSize =
        static_cast<double>(K_MIN_ENCODER_SIZE);
    if (targetW >= K_MIN_ENCODER_SIZE ||
        targetH >= K_MIN_ENCODER_SIZE) {
        if (targetW < K_MIN_ENCODER_SIZE) {
            targetW = K_MIN_ENCODER_SIZE;
            targetH = CeilByAspect(
                minSize, aspectRatio);
        } else if (targetH < K_MIN_ENCODER_SIZE) {
            targetH = K_MIN_ENCODER_SIZE;
            targetW = static_cast<int32_t>(
                std::ceil(minSize * aspectRatio));
        }
        return;
    }
    if (targetW >= targetH) {
        targetW = K_MIN_ENCODER_SIZE;
        targetH = CeilByAspect(
            minSize, aspectRatio);
    } else {
        targetH = K_MIN_ENCODER_SIZE;
        targetW = static_cast<int32_t>(
            std::ceil(minSize * aspectRatio));
    }
}

void ConvertYRow(
    const uint8_t *src, uint8_t *yDst,
    int32_t copyWidth, PixelFormat format)
{
    for (int32_t x = 0; x < copyWidth; ++x) {
        int r = 0;
        int g = 0;
        int b = 0;
        ExtractRgb(src, format, r, g, b);
        yDst[x] = RgbaToY(r, g, b);
        src += K_RGBA_BYTES_PER_PIXEL;
    }
}

void ConvertYPlaneData(
    const PlaneConvertInput &input,
    const PlaneInfo &yPlane)
{
    for (int32_t y = 0; y < input.copyHeight; ++y) {
        const uint8_t *src = input.rgba +
            static_cast<size_t>(y) * input.srcStride;
        uint8_t *yDst = yPlane.data +
            static_cast<size_t>(y) * yPlane.stride;
        ConvertYRow(
            src, yDst, input.copyWidth, input.format);
    }
}

void AccumulateRow(
    const uint8_t *srcRow, int32_t x,
    int32_t copyWidth, RgbAccumulator &acc,
    PixelFormat format)
{
    for (int32_t dx = 0;
         dx < K_UV_SUBSAMPLE && (x + dx) < copyWidth;
         ++dx) {
        const uint8_t *p = srcRow +
            static_cast<size_t>(x + dx) *
            K_RGBA_BYTES_PER_PIXEL;
        int r = 0;
        int g = 0;
        int b = 0;
        ExtractRgb(p, format, r, g, b);
        acc.rSum += r;
        acc.gSum += g;
        acc.bSum += b;
        acc.count++;
    }
}

RgbAverage SampleBlockAverage(
    const uint8_t *srcRow1,
    const uint8_t *srcRow2,
    int32_t x, int32_t copyWidth,
    PixelFormat format)
{
    RgbAccumulator acc;
    AccumulateRow(srcRow1, x, copyWidth, acc, format);
    if (srcRow2 != nullptr) {
        AccumulateRow(
            srcRow2, x, copyWidth, acc, format);
    }
    RgbAverage avg;
    if (acc.count > 0) {
        avg.r = acc.rSum / acc.count;
        avg.g = acc.gSum / acc.count;
        avg.b = acc.bSum / acc.count;
    }
    return avg;
}

void ConvertUvRow(
    const uint8_t *srcRow1, const uint8_t *srcRow2,
    uint8_t *uvDst, int32_t copyWidth,
    PixelFormat format)
{
    for (int32_t x = 0; x < copyWidth;
         x += K_UV_SUBSAMPLE) {
        RgbAverage avg = SampleBlockAverage(
            srcRow1, srcRow2, x, copyWidth, format);
        ComputeAndWriteUv(
            avg, &uvDst[x], &uvDst[x + 1]);
    }
}

void ConvertUvPlaneData(
    const PlaneConvertInput &input,
    const PlaneInfo &uvPlane)
{
    for (int32_t y = 0; y < input.copyHeight;
         y += K_UV_SUBSAMPLE) {
        const uint8_t *srcRow1 = input.rgba +
            static_cast<size_t>(y) * input.srcStride;
        const uint8_t *srcRow2 =
            (y + 1 < input.copyHeight)
            ? (input.rgba +
               static_cast<size_t>(y + 1) *
               input.srcStride)
            : nullptr;
        uint8_t *uvDst = uvPlane.data +
            static_cast<size_t>(y / K_UV_SUBSAMPLE) *
            uvPlane.stride;
        ConvertUvRow(
            srcRow1, srcRow2, uvDst,
            input.copyWidth, input.format);
    }
}

} // namespace

struct InputBufferInfo {
    uint32_t index = 0;
    OH_AVBuffer *buffer = nullptr;
};

struct OutputBufferInfo {
    uint32_t index = 0;
    OH_AVBuffer *buffer = nullptr;
    OH_AVCodecBufferAttr attr = {
        0, 0, 0, AVCODEC_BUFFER_FLAGS_NONE
    };
};

struct ReplayEncoder::CodecContext {
    std::mutex inputMutex;
    std::condition_variable inputCond;
    std::queue<InputBufferInfo> inputQueue;
    std::mutex outputMutex;
    std::condition_variable outputCond;
    std::queue<OutputBufferInfo> outputQueue;
    bool eosReceived = false;
    bool fatalError = false;
    ReplayEncoder *owner = nullptr;
};

void ReplayEncoder::OnCodecError(
    OH_AVCodec *codec, int32_t errorCode,
    void *userData)
{
    (void)codec;
    auto *ctx = static_cast<CodecContext *>(userData);
    if (ctx && ctx->owner) {
        ctx->owner->HandleCodecError(errorCode);
    }
}

void ReplayEncoder::OnCodecFormatChange(
    OH_AVCodec *codec, OH_AVFormat *format,
    void *userData)
{
    (void)codec;
    (void)format;
    auto *ctx = static_cast<CodecContext *>(userData);
    if (ctx && ctx->owner) {
        ctx->owner->HandleFormatChange();
    }
}

void ReplayEncoder::OnNeedInputBuffer(
    OH_AVCodec *codec, uint32_t index,
    OH_AVBuffer *buffer, void *userData)
{
    (void)codec;
    auto *ctx = static_cast<CodecContext *>(userData);
    if (!ctx || !ctx->owner || !buffer) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(
            ctx->inputMutex);
        ctx->inputQueue.push({index, buffer});
    }
    ctx->inputCond.notify_one();
}

void ReplayEncoder::OnNewOutputBuffer(
    OH_AVCodec *codec, uint32_t index,
    OH_AVBuffer *buffer, void *userData)
{
    (void)codec;
    auto *ctx = static_cast<CodecContext *>(userData);
    if (!ctx || !ctx->owner || !buffer) {
        return;
    }
    OutputBufferInfo info;
    info.index = index;
    info.buffer = buffer;
    (void)OH_AVBuffer_GetBufferAttr(
        buffer, &info.attr);
    if (info.attr.flags & AVCODEC_BUFFER_FLAGS_EOS) {
        ctx->eosReceived = true;
    }
    {
        std::lock_guard<std::mutex> lock(
            ctx->outputMutex);
        ctx->outputQueue.push(info);
    }
    ctx->outputCond.notify_one();
}

ReplayEncoder &ReplayEncoder::Instance()
{
    static ReplayEncoder instance;
    return instance;
}

ReplayEncoder::ReplayEncoder() = default;

ReplayEncoder::~ReplayEncoder()
{
    ResetState();
}

PixelFormat ReplayEncoder::ToPixelFormat(int32_t value)
{
    switch (value) {
        case static_cast<int32_t>(PixelFormat::BGRA8888):
            return PixelFormat::BGRA8888;
        case static_cast<int32_t>(PixelFormat::ARGB8888):
            return PixelFormat::ARGB8888;
        case static_cast<int32_t>(PixelFormat::RGBA8888):
        default:
            return PixelFormat::RGBA8888;
    }
}

void ReplayEncoder::ReleaseEncoder()
{
    if (videoEncoder_ != nullptr) {
        if (encoderStarted_) {
            OH_VideoEncoder_Flush(videoEncoder_);
            OH_VideoEncoder_Stop(videoEncoder_);
        }
        OH_VideoEncoder_Destroy(videoEncoder_);
        videoEncoder_ = nullptr;
    }
    if (nativeWindow_ != nullptr) {
        OH_NativeWindow_DestroyNativeWindow(
            nativeWindow_);
        nativeWindow_ = nullptr;
    }
}

void ReplayEncoder::ReleaseMuxer()
{
    if (muxer_ != nullptr) {
        if (muxerStarted_) {
            (void)OH_AVMuxer_Stop(muxer_);
        }
        OH_AVMuxer_Destroy(muxer_);
        muxer_ = nullptr;
    }
}

void ReplayEncoder::CleanupResources()
{
    stopRequested_.store(true);
    if (context_) {
        context_->inputCond.notify_all();
        context_->outputCond.notify_all();
    }
    if (drainThread_.joinable()) {
        drainThread_.join();
    }
    ReleaseEncoder();
    ReleaseMuxer();
    if (duplicatedFd_ >= 0) {
        close(duplicatedFd_);
        duplicatedFd_ = -1;
    }
    context_.reset();
}

void ReplayEncoder::ResetMemberVariables()
{
    nv12Buffer_.clear();
    expectedFrameSize_ = 0;
    yStride_ = 0;
    uvStride_ = 0;
    yPlaneSize_ = 0;
    uvPlaneSize_ = 0;
    firstFrame_ = true;
    frameCount_ = 0;
    writtenSamples_ = 0;
    lastPtsUs_ = 0;
    basePtsUs_ = 0;
    hasBasePts_ = false;
    frameDurationUs_ = 0;
    muxerStarted_ = false;
    encoderStarted_ = false;
    ready_ = false;
    width_ = 0;
    height_ = 0;
    fps_ = 0;
    mimeType_.clear();
    stopRequested_.store(false);
}

void ReplayEncoder::ResetState()
{
    CleanupResources();
    ResetMemberVariables();
}

void ReplayEncoder::CalculateNv12Layout()
{
    yStride_ = static_cast<uint32_t>(
        (width_ + K_STRIDE_ALIGNMENT - 1) /
        K_STRIDE_ALIGNMENT * K_STRIDE_ALIGNMENT);
    uvStride_ = yStride_;
    yPlaneSize_ =
        static_cast<size_t>(yStride_) *
        static_cast<size_t>(height_);
    uvPlaneSize_ =
        static_cast<size_t>(uvStride_) *
        static_cast<size_t>((height_ + 1) /
                            K_UV_SUBSAMPLE);
    expectedFrameSize_ = yPlaneSize_ + uvPlaneSize_;
    nv12Buffer_.resize(expectedFrameSize_);
}

bool ReplayEncoder::SetupResolution(
    int32_t width, int32_t height)
{
    double aspectRatio =
        static_cast<double>(width) /
        static_cast<double>(height);
    int32_t targetW = width;
    int32_t targetH = height;
    AlignToMinSize(targetW, targetH, aspectRatio);
    width_ =
        ((targetW + K_RESOLUTION_ALIGNMENT - 1) /
         K_RESOLUTION_ALIGNMENT) *
        K_RESOLUTION_ALIGNMENT;
    height_ =
        ((targetH + K_RESOLUTION_ALIGNMENT - 1) /
         K_RESOLUTION_ALIGNMENT) *
        K_RESOLUTION_ALIGNMENT;
    if (width_ != width || height_ != height) {
        REPLAY_LOG(LOG_WARN,
            "Resolution aligned "
            "%{public}dx%{public}d -> "
            "%{public}dx%{public}d",
            width, height, width_, height_);
    }
    CalculateNv12Layout();
    return true;
}

bool ReplayEncoder::CreateMuxerTrack(int64_t bitrate)
{
    muxer_ = OH_AVMuxer_Create(
        duplicatedFd_, AV_OUTPUT_FORMAT_MPEG_4);
    if (!muxer_) {
        REPLAY_LOG(LOG_ERROR,
            "OH_AVMuxer_Create failed");
        return false;
    }
    std::vector<char> mime(
        mimeType_.begin(), mimeType_.end());
    mime.push_back('\0');
    OH_AVFormat *fmt =
        OH_AVFormat_CreateVideoFormat(
            mime.data(), width_, height_);
    if (!fmt) {
        REPLAY_LOG(LOG_ERROR,
            "CreateVideoFormat failed");
        return false;
    }
    OH_AVFormat_SetDoubleValue(
        fmt, OH_MD_KEY_FRAME_RATE,
        static_cast<double>(fps_));
    OH_AVFormat_SetIntValue(
        fmt, OH_MD_KEY_WIDTH, width_);
    OH_AVFormat_SetIntValue(
        fmt, OH_MD_KEY_HEIGHT, height_);
    OH_AVFormat_SetLongValue(
        fmt, OH_MD_KEY_BITRATE, bitrate);
    int32_t ret = OH_AVMuxer_AddTrack(
        muxer_, &videoTrackId_, fmt);
    OH_AVFormat_Destroy(fmt);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR,
            "AddTrack failed ret=%{public}d", ret);
        return false;
    }
    return true;
}

bool ReplayEncoder::ConfigureEncoder(int64_t bitrate)
{
    std::vector<char> mime(
        mimeType_.begin(), mimeType_.end());
    mime.push_back('\0');
    videoEncoder_ = OH_VideoEncoder_CreateByMime(
        mime.data());
    if (!videoEncoder_) {
        REPLAY_LOG(LOG_ERROR,
            "CreateByMime failed");
        return false;
    }
    OH_AVFormat *fmt = OH_AVFormat_Create();
    if (!fmt) {
        REPLAY_LOG(LOG_ERROR,
            "AVFormat_Create failed");
        return false;
    }
    OH_AVFormat_SetIntValue(
        fmt, OH_MD_KEY_WIDTH, width_);
    OH_AVFormat_SetIntValue(
        fmt, OH_MD_KEY_HEIGHT, height_);
    OH_AVFormat_SetDoubleValue(
        fmt, OH_MD_KEY_FRAME_RATE,
        static_cast<double>(fps_));
    OH_AVFormat_SetIntValue(
        fmt, OH_MD_KEY_PIXEL_FORMAT,
        AV_PIXEL_FORMAT_NV12);
    OH_AVFormat_SetLongValue(
        fmt, OH_MD_KEY_BITRATE, bitrate);
    OH_AVFormat_SetIntValue(
        fmt, OH_MD_KEY_I_FRAME_INTERVAL,
        K_I_FRAME_INTERVAL);
    int32_t ret = OH_VideoEncoder_Configure(
        videoEncoder_, fmt);
    OH_AVFormat_Destroy(fmt);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR,
            "Configure failed ret=%{public}d", ret);
        return false;
    }
    return true;
}

bool ReplayEncoder::RegisterAndStartEncoder()
{
    context_ = std::make_unique<CodecContext>();
    context_->owner = this;
    OH_AVCodecCallback cb = {
        OnCodecError, OnCodecFormatChange,
        OnNeedInputBuffer, OnNewOutputBuffer
    };
    int32_t ret = OH_VideoEncoder_RegisterCallback(
        videoEncoder_, cb, context_.get());
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR,
            "RegisterCallback failed ret=%{public}d",
            ret);
        return false;
    }
    ret = OH_VideoEncoder_Prepare(videoEncoder_);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR,
            "Prepare failed ret=%{public}d", ret);
        return false;
    }
    ret = OH_VideoEncoder_Start(videoEncoder_);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR,
            "Start failed ret=%{public}d", ret);
        return false;
    }
    encoderStarted_ = true;
    return true;
}

int64_t ReplayEncoder::CalculateBitrate() const
{
    int64_t br =
        static_cast<int64_t>(width_) *
        static_cast<int64_t>(height_) * fps_ *
        K_BITRATE_NUMERATOR / K_BITRATE_DENOMINATOR;
    if (br < K_MIN_BITRATE) {
        br = K_MIN_BITRATE;
    }
    return br;
}

bool ReplayEncoder::StartMuxerAndDrainThread()
{
    int32_t ret = OH_AVMuxer_Start(muxer_);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR,
            "AVMuxer_Start failed ret=%{public}d",
            ret);
        return false;
    }
    muxerStarted_ = true;
    stopRequested_.store(false);
    drainThread_ = std::thread(
        &ReplayEncoder::DrainOutputLoop, this);
    ready_ = true;
    return true;
}

bool ReplayEncoder::InitValidateParams(
    int32_t fd, int32_t width, int32_t height,
    int32_t fps)
{
    if (fd < 0) {
        REPLAY_LOG(LOG_ERROR,
            "Init: invalid fd=%{public}d", fd);
        return false;
    }
    if (width <= 0 || height <= 0 || fps <= 0) {
        REPLAY_LOG(LOG_ERROR,
            "Init: invalid params "
            "%{public}dx%{public}d fps=%{public}d",
            width, height, fps);
        return false;
    }
    return true;
}

bool ReplayEncoder::InitSetupFdAndResolution(
    int32_t fd, int32_t width, int32_t height,
    int32_t fps, const std::string &mimeType)
{
    duplicatedFd_ = dup(fd);
    if (duplicatedFd_ < 0) {
        REPLAY_LOG(LOG_ERROR,
            "Init: dup failed errno=%{public}d",
            errno);
        return false;
    }
    mimeType_ =
        mimeType.empty() ? "video/avc" : mimeType;
    fps_ = fps;
    if (!SetupResolution(width, height)) {
        return false;
    }
    frameDurationUs_ = (fps_ > 0)
        ? (K_US_PER_SECOND / fps_)
        : K_FALLBACK_FRAME_DURATION_US;
    return true;
}

bool ReplayEncoder::InitCreateComponents(
    int64_t bitrate)
{
    if (!CreateMuxerTrack(bitrate)) {
        return false;
    }
    if (!ConfigureEncoder(bitrate)) {
        return false;
    }
    if (!RegisterAndStartEncoder()) {
        return false;
    }
    if (!StartMuxerAndDrainThread()) {
        return false;
    }
    return true;
}

bool ReplayEncoder::Init(
    int32_t fd, int32_t width, int32_t height,
    int32_t fps, const std::string &mimeType)
{
    ResetState();
    if (!InitValidateParams(fd, width, height, fps)) {
        return false;
    }
    if (!InitSetupFdAndResolution(
        fd, width, height, fps, mimeType)) {
        ResetState();
        return false;
    }
    int64_t bitrate = CalculateBitrate();
    if (!InitCreateComponents(bitrate)) {
        ResetState();
        return false;
    }
    REPLAY_LOG(LOG_INFO,
        "Init OK %{public}dx%{public}d fps=%{public}d "
        "stride=%{public}u frameSize=%{public}zu",
        width_, height_, fps_, yStride_,
        expectedFrameSize_);
    return true;
}

bool ReplayEncoder::AcquireInputBuffer(
    uint32_t &index, OH_AVBuffer *&buf)
{
    std::unique_lock<std::mutex> lock(
        context_->inputMutex);
    bool ok = context_->inputCond.wait_for(
        lock,
        std::chrono::milliseconds(
            K_INPUT_BUFFER_TIMEOUT_MS),
        [this]() {
            return stopRequested_.load() ||
                (context_ &&
                 !context_->inputQueue.empty());
        });
    if (!ok || !context_ ||
        context_->inputQueue.empty()) {
        REPLAY_LOG(LOG_WARN,
            "Input buffer wait timeout");
        return false;
    }
    InputBufferInfo info =
        context_->inputQueue.front();
    context_->inputQueue.pop();
    index = info.index;
    buf = info.buffer;
    return true;
}

uint8_t *ReplayEncoder::PrepareInputBuffer(
    OH_AVBuffer *buffer)
{
    auto *dest = static_cast<uint8_t *>(
        OH_AVBuffer_GetAddr(buffer));
    if (!dest) {
        REPLAY_LOG(LOG_ERROR, "buffer addr null");
        return nullptr;
    }
    int32_t cap = OH_AVBuffer_GetCapacity(buffer);
    if (cap > 0) {
        size_t capSize = static_cast<size_t>(cap);
        if (capSize < expectedFrameSize_) {
            REPLAY_LOG(LOG_ERROR,
                "buffer cap %{public}zu < "
                "expected %{public}zu",
                capSize, expectedFrameSize_);
            return nullptr;
        }
        std::fill_n(dest, yPlaneSize_,
                    static_cast<uint8_t>(0));
        std::fill_n(dest + yPlaneSize_, uvPlaneSize_,
                    K_UV_NEUTRAL);
    }
    return dest;
}

bool ReplayEncoder::SubmitInputBuffer(
    OH_AVBuffer *buffer, uint32_t bufIndex,
    int64_t ptsUs)
{
    OH_AVCodecBufferAttr attr = {};
    attr.size =
        static_cast<uint32_t>(expectedFrameSize_);
    attr.offset = 0;
    attr.pts = ptsUs;
    attr.flags = firstFrame_
        ? AVCODEC_BUFFER_FLAGS_SYNC_FRAME
        : AVCODEC_BUFFER_FLAGS_NONE;
    int32_t ret =
        OH_AVBuffer_SetBufferAttr(buffer, &attr);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR,
            "SetBufferAttr failed ret=%{public}d",
            ret);
        return false;
    }
    ret = OH_VideoEncoder_PushInputBuffer(
        videoEncoder_, bufIndex);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR,
            "PushInputBuffer failed ret=%{public}d",
            ret);
        return false;
    }
    return true;
}

int64_t ReplayEncoder::ComputePresentationTime(
    int64_t timestampMs)
{
    int64_t candidateUs =
        timestampMs * K_MS_TO_US_MULTIPLIER;
    if (!hasBasePts_) {
        basePtsUs_ = candidateUs;
        hasBasePts_ = true;
    }
    int64_t ptsUs = candidateUs - basePtsUs_;
    if (ptsUs < 0) {
        ptsUs = 0;
    }
    if (ptsUs <= lastPtsUs_) {
        ptsUs = lastPtsUs_ + frameDurationUs_;
    }
    return ptsUs;
}

void ReplayEncoder::LogEncodePerformance(
    int64_t waitUs, int64_t convertUs,
    int64_t pushUs, int64_t totalUs)
{
    bool shouldLog =
        (frameCount_ % K_PERF_LOG_INTERVAL == 1) ||
        (waitUs > K_PERF_WAIT_THRESHOLD_US) ||
        (convertUs > K_PERF_CONVERT_THRESHOLD_US) ||
        (pushUs > K_PERF_PUSH_THRESHOLD_US) ||
        (totalUs > K_PERF_TOTAL_THRESHOLD_US);
    if (shouldLog) {
        REPLAY_LOG(LOG_INFO,
            "[PERF] frame=%{public}" PRIu64
            " wait=%{public}lldus"
            " cvt=%{public}lldus"
            " push=%{public}lldus"
            " total=%{public}lldus",
            frameCount_,
            static_cast<long long>(waitUs),
            static_cast<long long>(convertUs),
            static_cast<long long>(pushUs),
            static_cast<long long>(totalUs));
    }
}

bool ReplayEncoder::AcquireAndConvertFrame(
    const Nv12ConvertInput &cvt,
    int64_t ptsUs)
{
    uint32_t bufIdx = 0;
    OH_AVBuffer *buf = nullptr;
    if (!AcquireInputBuffer(bufIdx, buf)) {
        return false;
    }
    uint8_t *dest = PrepareInputBuffer(buf);
    if (!dest) {
        return false;
    }
    Nv12ConvertInput actual = cvt;
    actual.dest = dest;
    if (!ConvertRgbaToNv12(actual)) {
        return false;
    }
    return SubmitInputBuffer(buf, bufIdx, ptsUs);
}

bool ReplayEncoder::Encode(
    const void *rgba, size_t size,
    int64_t timestampMs,
    const EncodeInputInfo &input)
{
    if (!ready_ || !rgba) {
        return false;
    }
    int32_t realW =
        (input.width > 0) ? input.width : width_;
    int32_t realH =
        (input.height > 0) ? input.height : height_;
    size_t stride = ComputeStride(input.stride, realW);
    if (size < stride * static_cast<size_t>(realH)) {
        return false;
    }
    int64_t ptsUs =
        ComputePresentationTime(timestampMs);
    Nv12ConvertInput cvt;
    cvt.rgba = static_cast<const uint8_t *>(rgba);
    cvt.srcStride = stride;
    cvt.copyWidth = std::min(width_, realW);
    cvt.copyHeight = std::min(height_, realH);
    cvt.format = ToPixelFormat(input.pixelFormat);
    if (!AcquireAndConvertFrame(cvt, ptsUs)) {
        return false;
    }
    frameCount_++;
    firstFrame_ = false;
    lastPtsUs_ = ptsUs;
    return true;
}

bool ReplayEncoder::EncodePixelMap(
    void *pixelMapVoid, int64_t timestampMs)
{
    if (!ready_ || !pixelMapVoid) {
        return false;
    }
    NativePixelMap *pm =
        static_cast<NativePixelMap *>(pixelMapVoid);
    if (!EnsurePixelMapFuncs()) {
        REPLAY_LOG(LOG_ERROR,
            "EncodePixelMap: symbols unavailable");
        return false;
    }
    OHOS::Media::OhosPixelMapInfo info;
    int32_t ret = g_getImageInfo(pm, &info);
    if (ret != 0) {
        REPLAY_LOG(LOG_ERROR,
            "GetImageInfo failed ret=%{public}d", ret);
        return false;
    }
    void *pixels = nullptr;
    ret = g_accessPixels(pm, &pixels);
    if (ret != 0 || !pixels) {
        REPLAY_LOG(LOG_ERROR,
            "AccessPixels failed ret=%{public}d", ret);
        return false;
    }
    EncodeInputInfo encInput;
    encInput.stride =
        static_cast<int32_t>(info.rowSize);
    encInput.width =
        static_cast<int32_t>(info.width);
    encInput.height =
        static_cast<int32_t>(info.height);
    encInput.pixelFormat = info.pixelFormat;
    bool result = Encode(
        pixels,
        static_cast<size_t>(info.rowSize) *
        static_cast<size_t>(info.height),
        timestampMs, encInput);
    g_unAccessPixels(pm);
    return result;
}

void *ReplayEncoder::GetInputWindow()
{
    return static_cast<void *>(nativeWindow_);
}

void ReplayEncoder::SignalEndOfStream()
{
    if (!context_ || !videoEncoder_) {
        return;
    }
    uint32_t eosIdx = 0;
    OH_AVBuffer *eosBuf = nullptr;
    {
        std::unique_lock<std::mutex> lock(
            context_->inputMutex);
        bool ok = context_->inputCond.wait_for(
            lock,
            std::chrono::milliseconds(
                K_EOS_BUFFER_TIMEOUT_MS),
            [this]() {
                return stopRequested_.load() ||
                    (context_ &&
                     !context_->inputQueue.empty());
            });
        if (!ok || !context_ ||
            context_->inputQueue.empty()) {
            REPLAY_LOG(LOG_WARN,
                "SignalEOS: timeout for buffer");
            return;
        }
        InputBufferInfo info =
            context_->inputQueue.front();
        context_->inputQueue.pop();
        eosIdx = info.index;
        eosBuf = info.buffer;
    }
    OH_AVCodecBufferAttr eosAttr = {};
    eosAttr.size = 0;
    eosAttr.offset = 0;
    eosAttr.pts = lastPtsUs_ + frameDurationUs_;
    eosAttr.flags = AVCODEC_BUFFER_FLAGS_EOS;
    int32_t ret =
        OH_AVBuffer_SetBufferAttr(eosBuf, &eosAttr);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR,
            "SignalEOS: SetAttr ret=%{public}d", ret);
        return;
    }
    (void)OH_VideoEncoder_PushInputBuffer(
        videoEncoder_, eosIdx);
}

void ReplayEncoder::StopEncoder()
{
    if (videoEncoder_ == nullptr) {
        return;
    }
    if (encoderStarted_) {
        OH_VideoEncoder_Flush(videoEncoder_);
        OH_VideoEncoder_Stop(videoEncoder_);
    }
    OH_VideoEncoder_Destroy(videoEncoder_);
    videoEncoder_ = nullptr;
    encoderStarted_ = false;
}

void ReplayEncoder::StopMuxer()
{
    if (muxer_ == nullptr) {
        return;
    }
    if (muxerStarted_) {
        (void)OH_AVMuxer_Stop(muxer_);
    }
    (void)OH_AVMuxer_Destroy(muxer_);
    muxer_ = nullptr;
    muxerStarted_ = false;
}

void ReplayEncoder::WaitForEos()
{
    if (!context_) {
        return;
    }
    std::unique_lock<std::mutex> lock(
        context_->outputMutex);
    context_->outputCond.wait_for(
        lock,
        std::chrono::seconds(K_EOS_TIMEOUT_SECONDS),
        [this]() {
            return context_->eosReceived ||
                context_->fatalError;
        });
}

void ReplayEncoder::StopDrainThread()
{
    stopRequested_.store(true);
    if (context_) {
        context_->inputCond.notify_all();
        context_->outputCond.notify_all();
    }
    if (drainThread_.joinable()) {
        drainThread_.join();
    }
}

void ReplayEncoder::Finalize()
{
    if (frameCount_ > 0 &&
        videoEncoder_ != nullptr) {
        SignalEndOfStream();
        WaitForEos();
    }
    StopDrainThread();
    StopEncoder();
    StopMuxer();
    REPLAY_LOG(LOG_INFO,
        "Finalize done frames=%{public}" PRIu64
        " samples=%{public}" PRIu64,
        frameCount_, writtenSamples_);
    ResetState();
}

void ReplayEncoder::ProcessOutputInfo(
    const OutputBufferInfo &info)
{
    if (muxer_ && muxerStarted_) {
        int32_t ret =
            OH_AVMuxer_WriteSampleBuffer(
                muxer_, videoTrackId_,
                info.buffer);
        if (ret != AV_ERR_OK) {
            REPLAY_LOG(LOG_ERROR,
                "WriteSampleBuffer FAIL "
                "idx=%{public}u ret=%{public}d",
                info.index, ret);
        } else {
            writtenSamples_++;
        }
    }
    if (videoEncoder_) {
        (void)OH_VideoEncoder_FreeOutputBuffer(
            videoEncoder_, info.index);
    }
}

void ReplayEncoder::DrainMainLoop()
{
    while (!stopRequested_.load()) {
        OutputBufferInfo info;
        {
            std::unique_lock<std::mutex> lock(
                context_->outputMutex);
            context_->outputCond.wait(
                lock, [this]() {
                return stopRequested_.load() ||
                    (context_ &&
                     !context_->outputQueue.empty());
            });
            if (stopRequested_.load() &&
                (!context_ ||
                 context_->outputQueue.empty())) {
                break;
            }
            if (!context_ ||
                context_->outputQueue.empty()) {
                continue;
            }
            info = context_->outputQueue.front();
            context_->outputQueue.pop();
        }
        if (!info.buffer) {
            continue;
        }
        if (info.attr.flags &
            AVCODEC_BUFFER_FLAGS_EOS) {
            if (videoEncoder_) {
                (void)OH_VideoEncoder_FreeOutputBuffer(
                    videoEncoder_, info.index);
            }
            break;
        }
        ProcessOutputInfo(info);
    }
}

void ReplayEncoder::DrainRemainingBuffers()
{
    if (!context_) {
        return;
    }
    std::lock_guard<std::mutex> lock(
        context_->outputMutex);
    while (!context_->outputQueue.empty()) {
        OutputBufferInfo remaining =
            context_->outputQueue.front();
        context_->outputQueue.pop();
        if (!remaining.buffer) {
            continue;
        }
        bool isEos = (remaining.attr.flags &
            AVCODEC_BUFFER_FLAGS_EOS) != 0;
        if (!isEos) {
            ProcessOutputInfo(remaining);
        } else if (videoEncoder_) {
            (void)OH_VideoEncoder_FreeOutputBuffer(
                videoEncoder_, remaining.index);
        }
    }
}

void ReplayEncoder::DrainOutputLoop()
{
    ApplyBackgroundPriority();
    DrainMainLoop();
    DrainRemainingBuffers();
}

void ReplayEncoder::ApplyBackgroundPriority()
{
#ifdef __OHOS__
    pthread_t thread = pthread_self();
    int policy = 0;
    struct sched_param param;
    if (pthread_getschedparam(
        thread, &policy, &param) == 0) {
        const int minPri =
            sched_get_priority_min(policy);
        if (minPri != -1 &&
            param.sched_priority != minPri) {
            param.sched_priority = minPri;
            pthread_setschedparam(
                thread, policy, &param);
        }
    }
#endif
}

bool ReplayEncoder::ConvertRgbaToNv12(
    const Nv12ConvertInput &input)
{
    if (!input.rgba || !input.dest) {
        return false;
    }
    if (yStride_ == 0 || uvStride_ == 0) {
        return false;
    }
    PlaneInfo yPlane = {input.dest, yStride_};
    PlaneInfo uvPlane = {
        input.dest + yPlaneSize_, uvStride_};
    PlaneConvertInput cvt;
    cvt.rgba = input.rgba;
    cvt.srcStride = input.srcStride;
    cvt.copyWidth = input.copyWidth;
    cvt.copyHeight = input.copyHeight;
    cvt.format = input.format;
    ConvertYPlaneData(cvt, yPlane);
    ConvertUvPlaneData(cvt, uvPlane);
    return true;
}

void ReplayEncoder::HandleCodecError(int32_t errorCode)
{
    REPLAY_LOG(LOG_ERROR,
        "Codec error code=%{public}d", errorCode);
    if (context_) {
        context_->fatalError = true;
    }
}

void ReplayEncoder::HandleFormatChange()
{
    REPLAY_LOG(LOG_INFO, "Codec format changed");
}

#undef REPLAY_LOG
