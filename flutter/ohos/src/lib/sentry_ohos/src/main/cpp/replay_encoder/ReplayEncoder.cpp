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

#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cinttypes>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <queue>

#include "hilog/log.h"
#include "multimedia/image_framework/image_pixel_map_napi.h"
#include "multimedia/player_framework/native_avbuffer.h"
#include "multimedia/player_framework/native_avcodec_base.h"
#include "multimedia/player_framework/native_avcodec_videoencoder.h"
#include "multimedia/player_framework/native_averrors.h"
#include "multimedia/player_framework/native_avformat.h"
#include "multimedia/player_framework/native_avmuxer.h"
#include "native_buffer/native_buffer.h"

namespace
{  // anonymous
constexpr unsigned int REPLAY_LOG_DOMAIN = 0xD005760;
constexpr const char REPLAY_LOG_TAG[] = "ReplayEncoder";

#define REPLAY_LOG(level, fmt, ...) \
    OH_LOG_Print(LOG_APP, level, REPLAY_LOG_DOMAIN, REPLAY_LOG_TAG, fmt, ##__VA_ARGS__)

// 动态加载的函数指针
typedef int32_t (*OhPixelMapGetImageInfoFunc)(NativePixelMap *pixelMap,
                                              OHOS::Media::OhosPixelMapInfo *info);
typedef int32_t (*OhPixelMapAccessPixelsFunc)(NativePixelMap *pixelMap, void **pixels);
typedef int32_t (*OhPixelMapUnAccessPixelsFunc)(NativePixelMap *pixelMap);

static OhPixelMapGetImageInfoFunc g_getImageInfo = nullptr;
static OhPixelMapAccessPixelsFunc g_accessPixels = nullptr;
static OhPixelMapUnAccessPixelsFunc g_unAccessPixels = nullptr;

bool EnsurePixelMapFuncs()
{
    if (g_getImageInfo && g_accessPixels && g_unAccessPixels) {
        return true;
    }

    void *handle = dlopen("libpixelmap_ndk.z.so", RTLD_LAZY);
    if (!handle) {
        handle = dlopen("libimage_ndk.z.so", RTLD_LAZY);
    }
    if (!handle) {
        REPLAY_LOG(LOG_ERROR, "EnsurePixelMapFuncs: failed to dlopen");
        return false;
    }

    g_getImageInfo = (OhPixelMapGetImageInfoFunc)dlsym(handle, "OH_PixelMap_GetImageInfo");
    g_accessPixels = (OhPixelMapAccessPixelsFunc)dlsym(handle, "OH_PixelMap_AccessPixels");
    g_unAccessPixels = (OhPixelMapUnAccessPixelsFunc)dlsym(handle, "OH_PixelMap_UnAccessPixels");
    if (!g_getImageInfo || !g_accessPixels || !g_unAccessPixels) {
        REPLAY_LOG(LOG_ERROR, "EnsurePixelMapFuncs: failed to dlsym");
        return false;
    }
    return true;
}

// YUV 转换常量
constexpr int K_BYTE_MAX = 255;
constexpr int K_RGBA_CHANNELS = 4;
constexpr int K_UV_DOWNSAMPLE_FACTOR = 2;
constexpr int K_FULL_PIXEL_COUNT = 4;
constexpr int K_HALF_PIXEL_COUNT = 2;
constexpr int K_SHIFT_FOR_FOUR = 2;                 // 除以4的位移量
constexpr int K_SHIFT_FOR_TWO = 1;                  // 除以2的位移量
constexpr int K_FALLBACK_FRAME_DURATION_US = 1000;  // 默认帧间隔1ms

// UV平面高度计算 - 向上取整除以2
constexpr int K_UV_HEIGHT_DIVISOR = 2;
constexpr int K_DOWNSAMPLE_FACTOR = 2;

// 性能监控阈值（微秒）
constexpr int K_WAIT_TIME_THRESHOLD_US = 10000;     // 等待时间告警阈值
constexpr int K_CONVERT_TIME_THRESHOLD_US = 50000;  // 转换时间告警阈值
constexpr int K_PUSH_TIME_THRESHOLD_US = 5000;      // 推送时间告警阈值
constexpr int K_TOTAL_TIME_THRESHOLD_US = 100000;   // 总时间告警阈值
constexpr int K_LOG_INTERVAL = 20;                  // 日志输出间隔帧数

inline uint8_t ClampToByte(int value)
{
    return static_cast<uint8_t>(std::min(std::max(value, 0), K_BYTE_MAX));
}

void ConvertYPlane(const uint8_t *rgba, uint8_t *yPlane, int32_t width, int32_t height,
                   size_t srcStride, int32_t dstStride)
{
    for (int32_t y = 0; y < height; ++y) {
        const uint8_t *src = rgba + y * srcStride;
        uint8_t *dst = yPlane + y * dstStride;
        for (int32_t x = 0; x < width; ++x) {
            int r = src[x * 4];
            int g = src[x * 4 + 1];
            int b = src[x * 4 + 2];
            int yVal = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
            dst[x] = ClampToByte(yVal);
        }
    }
}

void ConvertUVPlane(const uint8_t *rgba, uint8_t *uvPlane, int32_t width, int32_t height,
                    size_t srcStride, int32_t dstStride)
{
    for (int32_t y = 0; y < height; y += K_DOWNSAMPLE_FACTOR) {
        const uint8_t *src = rgba + y * srcStride;
        uint8_t *dst = uvPlane + (y / K_DOWNSAMPLE_FACTOR) * dstStride;
        for (int32_t x = 0; x < width; x += K_DOWNSAMPLE_FACTOR) {
            int r = src[x * 4];
            int g = src[x * 4 + 1];
            int b = src[x * 4 + 2];
            int uVal = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
            int vVal = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
            // UV are interleaved: U V U V...
            // dst[x] is U, dst[x+1] is V.
            // Since x increments by 2, this fills the line 0,1, 2,3, ... correctly.
            dst[x] = ClampToByte(uVal);
            dst[x + 1] = ClampToByte(vVal);
        }
    }
}
}  // namespace

struct InputBufferInfo
{
    uint32_t index = 0;
    OH_AVBuffer *buffer = nullptr;
};

struct OutputBufferInfo
{
    uint32_t index = 0;
    OH_AVBuffer *buffer = nullptr;
    OH_AVCodecBufferAttr attr{0, 0, 0, AVCODEC_BUFFER_FLAGS_NONE};
};

struct ReplayEncoder::CodecContext
{
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

void ReplayEncoder::OnCodecError(OH_AVCodec *codec, int32_t errorCode, void *userData)
{
    (void)codec;
    auto *ctx = static_cast<CodecContext *>(userData);
    if (ctx && ctx->owner) {
        ctx->owner->HandleCodecError(errorCode);
    }
}

void ReplayEncoder::OnCodecFormatChange(OH_AVCodec *codec, OH_AVFormat *format, void *userData)
{
    (void)codec;
    (void)format;
    auto *ctx = static_cast<CodecContext *>(userData);
    if (ctx && ctx->owner) {
        ctx->owner->HandleFormatChange();
    }
}

void ReplayEncoder::OnNeedInputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer,
                                      void *userData)
{
    (void)codec;
    auto *ctx = static_cast<CodecContext *>(userData);
    if (!ctx || !ctx->owner || !buffer) {
        return;
    }

    {
        std::lock_guard<std::mutex> lock(ctx->inputMutex);
        ctx->inputQueue.push({index, buffer});
    }
    ctx->inputCond.notify_one();
    REPLAY_LOG(LOG_DEBUG, "OnNeedInputBuffer index=%{public}u queue=%{public}zu", index,
               static_cast<size_t>(ctx->inputQueue.size()));
}

void ReplayEncoder::OnNewOutputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer,
                                      void *userData)
{
    (void)codec;
    auto *ctx = static_cast<CodecContext *>(userData);
    if (!ctx || !ctx->owner || !buffer) {
        return;
    }

    OutputBufferInfo info;
    info.index = index;
    info.buffer = buffer;
    int32_t ret = OH_AVBuffer_GetBufferAttr(buffer, &info.attr);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR, "OnNewOutputBuffer GetAttr failed ret=%{public}d", ret);
    }

    if (info.attr.flags & AVCODEC_BUFFER_FLAGS_EOS) {
        ctx->eosReceived = true;
    }

    {
        std::lock_guard<std::mutex> lock(ctx->outputMutex);
        ctx->outputQueue.push(info);
    }
    ctx->outputCond.notify_one();

    REPLAY_LOG(LOG_DEBUG,
               "OnNewOutputBuffer index=%{public}u flags=%{public}u "
               "size=%{public}u pts=%{public}" PRId64,
               index, info.attr.flags, info.attr.size, info.attr.pts);
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

void ReplayEncoder::ResetState()
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

    context_.reset();
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

// ============ Init() 辅助函数 ============

bool ReplayEncoder::ValidateInitParams(int32_t fd, int32_t width, int32_t height, int32_t fps)
{
    if (fd < 0) {
        REPLAY_LOG(LOG_ERROR, "Init failed: invalid fd");
        return false;
    }
    if (width <= 0 || height <= 0 || fps <= 0) {
        REPLAY_LOG(LOG_ERROR, "Init failed: invalid dimension or fps");
        return false;
    }
    return true;
}

void ReplayEncoder::CalculateAlignedDimensions(int32_t width, int32_t height)
{
    constexpr int32_t kMinSize = 256;
    constexpr int32_t kAlignment = 16;

    double aspectRatio =
        (width > 0 && height > 0) ? static_cast<double>(width) / static_cast<double>(height) : 1.0;

    int32_t targetWidth = width;
    int32_t targetHeight = height;

    if (targetWidth < kMinSize && targetHeight < kMinSize) {
        if (targetWidth >= targetHeight) {
            targetWidth = kMinSize;
            targetHeight =
                static_cast<int32_t>(std::ceil(static_cast<double>(kMinSize) / aspectRatio));
        } else {
            targetHeight = kMinSize;
            targetWidth =
                static_cast<int32_t>(std::ceil(static_cast<double>(kMinSize) * aspectRatio));
        }
    } else if (targetWidth < kMinSize) {
        targetWidth = kMinSize;
        targetHeight = static_cast<int32_t>(std::ceil(static_cast<double>(kMinSize) / aspectRatio));
    } else if (targetHeight < kMinSize) {
        targetHeight = kMinSize;
        targetWidth = static_cast<int32_t>(std::ceil(static_cast<double>(kMinSize) * aspectRatio));
    }

    width_ = ((targetWidth + kAlignment - 1) / kAlignment) * kAlignment;
    height_ = ((targetHeight + kAlignment - 1) / kAlignment) * kAlignment;

    if (width_ != width || height_ != height) {
        REPLAY_LOG(LOG_WARN,
                   "Resolution aligned from %{public}dx%{public}d "
                   "to %{public}dx%{public}d",
                   width, height, width_, height_);
    }
}

bool ReplayEncoder::CreateMuxer(int32_t fd)
{
    duplicatedFd_ = dup(fd);
    if (duplicatedFd_ < 0) {
        REPLAY_LOG(LOG_ERROR, "Init failed: dup errno=%{public}d", errno);
        return false;
    }

    muxer_ = OH_AVMuxer_Create(duplicatedFd_, AV_OUTPUT_FORMAT_MPEG_4);
    if (!muxer_) {
        REPLAY_LOG(LOG_ERROR, "OH_AVMuxer_Create failed");
        return false;
    }
    return true;
}

bool ReplayEncoder::CreateEncoder(const std::string &mimeTypeCopy)
{
    OH_AVFormat *trackFormat = OH_AVFormat_CreateVideoFormat(mimeTypeCopy.data(), width_, height_);
    if (!trackFormat) {
        REPLAY_LOG(LOG_ERROR, "CreateVideoFormat failed");
        return false;
    }

    constexpr int64_t kMinBitrate = 100000;
    int64_t bitrate = static_cast<int64_t>(width_) * static_cast<int64_t>(height_) * fps_ * 3 / 4;
    if (bitrate < kMinBitrate) {
        bitrate = kMinBitrate;
    }

    OH_AVFormat_SetDoubleValue(trackFormat, OH_MD_KEY_FRAME_RATE, static_cast<double>(fps_));
    OH_AVFormat_SetIntValue(trackFormat, OH_MD_KEY_WIDTH, width_);
    OH_AVFormat_SetIntValue(trackFormat, OH_MD_KEY_HEIGHT, height_);
    OH_AVFormat_SetLongValue(trackFormat, OH_MD_KEY_BITRATE, bitrate);

    int32_t ret = OH_AVMuxer_AddTrack(muxer_, &videoTrackId_, trackFormat);
    OH_AVFormat_Destroy(trackFormat);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR, "AddTrack failed ret=%{public}d", ret);
        return false;
    }

    videoEncoder_ = OH_VideoEncoder_CreateByMime(mimeTypeCopy.data());
    if (!videoEncoder_) {
        REPLAY_LOG(LOG_ERROR, "CreateByMime failed");
        return false;
    }

    return ConfigureEncoder(bitrate);
}

bool ReplayEncoder::ConfigureEncoder(int64_t bitrate)
{
    OH_AVFormat *encoderFormat = OH_AVFormat_Create();
    if (!encoderFormat) {
        REPLAY_LOG(LOG_ERROR, "AVFormat_Create failed");
        return false;
    }

    OH_AVFormat_SetIntValue(encoderFormat, OH_MD_KEY_WIDTH, width_);
    OH_AVFormat_SetIntValue(encoderFormat, OH_MD_KEY_HEIGHT, height_);
    OH_AVFormat_SetDoubleValue(encoderFormat, OH_MD_KEY_FRAME_RATE, static_cast<double>(fps_));
    OH_AVFormat_SetIntValue(encoderFormat, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    OH_AVFormat_SetLongValue(encoderFormat, OH_MD_KEY_BITRATE, bitrate);
    constexpr int32_t kIFrameInterval = 1000;
    OH_AVFormat_SetIntValue(encoderFormat, OH_MD_KEY_I_FRAME_INTERVAL, kIFrameInterval);

    int32_t ret = OH_VideoEncoder_Configure(videoEncoder_, encoderFormat);
    OH_AVFormat_Destroy(encoderFormat);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR, "VideoEncoder_Configure failed ret=%{public}d", ret);
        return false;
    }

    context_ = std::make_unique<CodecContext>();
    context_->owner = this;

    ret = OH_VideoEncoder_RegisterCallback(
        videoEncoder_, {OnCodecError, OnCodecFormatChange, OnNeedInputBuffer, OnNewOutputBuffer},
        context_.get());
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR, "RegisterCallback failed ret=%{public}d", ret);
        return false;
    }
    return true;
}

bool ReplayEncoder::StartEncoderAndMuxer()
{
    int32_t ret = OH_VideoEncoder_Prepare(videoEncoder_);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR, "VideoEncoder_Prepare failed ret=%{public}d", ret);
        return false;
    }

    ret = OH_VideoEncoder_Start(videoEncoder_);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR, "VideoEncoder_Start failed ret=%{public}d", ret);
        return false;
    }
    encoderStarted_ = true;

    ret = OH_AVMuxer_Start(muxer_);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR, "AVMuxer_Start failed ret=%{public}d", ret);
        return false;
    }
    muxerStarted_ = true;

    stopRequested_.store(false);
    drainThread_ = std::thread(&ReplayEncoder::DrainOutputLoop, this);
    return true;
}

// ============ Encode() 辅助函数 ============

bool ReplayEncoder::WaitForInputBuffer(uint32_t &index, OH_AVBuffer *&buffer)
{
    InputBufferInfo bufferInfo;
    {
        std::unique_lock<std::mutex> lock(context_->inputMutex);
        bool ok = context_->inputCond.wait_for(lock, std::chrono::milliseconds(500), [this]() {
            return stopRequested_.load() || (context_ && !context_->inputQueue.empty());
        });
        if (!ok || !context_ || context_->inputQueue.empty()) {
            REPLAY_LOG(LOG_WARN, "Encode timed out waiting for input buffer");
            return false;
        }
        bufferInfo = context_->inputQueue.front();
        context_->inputQueue.pop();
    }
    index = bufferInfo.index;
    buffer = bufferInfo.buffer;
    return true;
}

bool ReplayEncoder::PrepareAndPushInputData(const PrepareInputParams &params)
{
    auto *dest = static_cast<uint8_t *>(OH_AVBuffer_GetAddr(params.buffer));
    if (!dest) {
        REPLAY_LOG(LOG_ERROR, "Encode failed: buffer addr null");
        return false;
    }

    int32_t capacityRet = OH_AVBuffer_GetCapacity(params.buffer);
    if (capacityRet > 0) {
        size_t capacitySize = static_cast<size_t>(capacityRet);
        std::fill_n(dest, capacitySize, 0);
    }

    ConvertParams convertParams{params.rgba,        params.size,       dest,
                                params.inputStride, params.inputWidth, params.inputHeight};
    if (!ConvertRgbaToNv12(convertParams)) {
        REPLAY_LOG(LOG_ERROR, "Encode failed: RGBA->NV12 conversion error");
        return false;
    }

    OH_AVCodecBufferAttr attr{0};
    attr.size = static_cast<uint32_t>(expectedFrameSize_);
    attr.offset = 0;
    attr.pts = params.ptsUs;
    attr.flags = firstFrame_ ? AVCODEC_BUFFER_FLAGS_SYNC_FRAME : AVCODEC_BUFFER_FLAGS_NONE;

    int32_t ret = OH_AVBuffer_SetBufferAttr(params.buffer, &attr);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR, "SetBufferAttr failed ret=%{public}d", ret);
        return false;
    }

    ret = OH_VideoEncoder_PushInputBuffer(videoEncoder_, params.index);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR, "PushInputBuffer failed ret=%{public}d", ret);
        return false;
    }
    return true;
}

// ============ Finalize() 辅助函数 ============

void ReplayEncoder::SignalEndOfStream()
{
    if (!context_ || !videoEncoder_) {
        return;
    }

    InputBufferInfo eosBufferInfo;
    {
        std::unique_lock<std::mutex> lock(context_->inputMutex);
        bool ok = context_->inputCond.wait_for(lock, std::chrono::seconds(2), [this]() {
            return stopRequested_.load() || (context_ && !context_->inputQueue.empty());
        });
        if (!ok || !context_ || context_->inputQueue.empty()) {
            REPLAY_LOG(LOG_WARN, "Finalize: timeout waiting for EOS buffer");
            return;
        }
        eosBufferInfo = context_->inputQueue.front();
        context_->inputQueue.pop();
    }

    OH_AVCodecBufferAttr eosAttr{0};
    eosAttr.size = 0;
    eosAttr.offset = 0;
    eosAttr.pts = lastPtsUs_ + frameDurationUs_;
    eosAttr.flags = AVCODEC_BUFFER_FLAGS_EOS;

    int32_t ret = OH_AVBuffer_SetBufferAttr(eosBufferInfo.buffer, &eosAttr);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR, "Finalize: SetBufferAttr(EOS) failed=%{public}d", ret);
        return;
    }

    ret = OH_VideoEncoder_PushInputBuffer(videoEncoder_, eosBufferInfo.index);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR, "Finalize: PushInputBuffer(EOS) failed=%{public}d", ret);
    }
}

void ReplayEncoder::WaitForDrainThread()
{
    if (!context_) {
        return;
    }

    REPLAY_LOG(LOG_INFO, "Finalize: waiting for drain thread");
    {
        std::unique_lock<std::mutex> lock(context_->outputMutex);
        bool done = context_->outputCond.wait_for(lock, std::chrono::seconds(5), [this]() {
            return context_->eosReceived || context_->fatalError;
        });
        if (!done) {
            REPLAY_LOG(LOG_WARN, "Finalize: timeout waiting for EOS from encoder");
        }
    }
}

// ============ ResetState() 辅助函数 ============

void ReplayEncoder::ReleaseEncoder()
{
    if (videoEncoder_ != nullptr) {
        if (encoderStarted_) {
            REPLAY_LOG(LOG_INFO, "Stopping video encoder");
            OH_VideoEncoder_Flush(videoEncoder_);
            OH_VideoEncoder_Stop(videoEncoder_);
        }
        OH_VideoEncoder_Destroy(videoEncoder_);
        videoEncoder_ = nullptr;
    }

    if (nativeWindow_ != nullptr) {
        OH_NativeWindow_DestroyNativeWindow(nativeWindow_);
        nativeWindow_ = nullptr;
    }
}

void ReplayEncoder::ReleaseMuxer()
{
    if (muxer_ != nullptr) {
        if (muxerStarted_) {
            REPLAY_LOG(LOG_INFO, "Stopping muxer");
            OH_AVMuxer_Stop(muxer_);
        }
        OH_AVMuxer_Destroy(muxer_);
        muxer_ = nullptr;
    }

    if (duplicatedFd_ >= 0) {
        close(duplicatedFd_);
        duplicatedFd_ = -1;
    }
}

bool ReplayEncoder::Init(int32_t fd, int32_t width, int32_t height, int32_t fps,
                         const std::string &mimeType)
{
    const std::string mimeTypeCopy = mimeType;
    REPLAY_LOG(LOG_INFO,
               "Init begin fd=%{public}d width=%{public}d height=%{public}d "
               "fps=%{public}d mime=%{public}s",
               fd, width, height, fps, mimeType.c_str());

    ResetState();

    if (!ValidateInitParams(fd, width, height, fps)) {
        return false;
    }

    CalculateAlignedDimensions(width, height);

    mimeType_ = mimeType.empty() ? "video/avc" : mimeType;
    fps_ = fps;
    frameDurationUs_ = fps_ > 0 ? (1000000LL / fps_) : 0;
    if (frameDurationUs_ <= 0) {
        frameDurationUs_ = K_FALLBACK_FRAME_DURATION_US;
    }

    CalculateBufferSizes();

    if (!CreateMuxer(fd)) {
        ResetState();
        return false;
    }

    if (!CreateEncoder(mimeTypeCopy)) {
        ResetState();
        return false;
    }

    if (!StartEncoderAndMuxer()) {
        ResetState();
        return false;
    }

    ready_ = true;
    firstFrame_ = true;
    frameCount_ = 0;
    lastPtsUs_ = 0;

    REPLAY_LOG(LOG_INFO, "Init success encoder ready");
    return true;
}

void ReplayEncoder::CalculateBufferSizes()
{
    yStride_ = static_cast<uint32_t>(width_);
    uvStride_ = static_cast<uint32_t>(width_);
    yPlaneSize_ = static_cast<size_t>(width_) * static_cast<size_t>(height_);
    uvPlaneSize_ = static_cast<size_t>(width_) * static_cast<size_t>(height_) / K_UV_HEIGHT_DIVISOR;
    expectedFrameSize_ = yPlaneSize_ + uvPlaneSize_;
    nv12Buffer_.resize(expectedFrameSize_);
}

bool ReplayEncoder::AcquireInputBuffer(InputBufferInfo &bufferInfo, int64_t &waitTimeUs)
{
    auto start = std::chrono::steady_clock::now();
    uint32_t index = 0;
    OH_AVBuffer *buffer = nullptr;
    if (!WaitForInputBuffer(index, buffer)) {
        return false;
    }
    bufferInfo.index = index;
    bufferInfo.buffer = buffer;
    auto end = std::chrono::steady_clock::now();
    waitTimeUs = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
    return true;
}

int64_t ReplayEncoder::CalculatePts(int64_t timestampMs)
{
    int64_t ptsUs = timestampMs * 1000;
    if (!hasBasePts_) {
        basePtsUs_ = ptsUs;
        hasBasePts_ = true;
    }
    return ptsUs - basePtsUs_;
}

bool ReplayEncoder::SubmitEncodedFrame(const InputBufferInfo &bufferInfo, int64_t ptsUs)
{
    OH_AVCodecBufferAttr attr{0};
    attr.size = static_cast<uint32_t>(expectedFrameSize_);
    attr.offset = 0;
    attr.pts = ptsUs;
    attr.flags = firstFrame_ ? AVCODEC_BUFFER_FLAGS_SYNC_FRAME : AVCODEC_BUFFER_FLAGS_NONE;

    int32_t ret = OH_AVBuffer_SetBufferAttr(bufferInfo.buffer, &attr);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR, "SetBufferAttr failed ret=%{public}d", ret);
        return false;
    }

    ret = OH_VideoEncoder_PushInputBuffer(videoEncoder_, bufferInfo.index);
    if (ret != AV_ERR_OK) {
        REPLAY_LOG(LOG_ERROR, "PushInputBuffer failed ret=%{public}d", ret);
        return false;
    }
    return true;
}

void ReplayEncoder::LogEncodePerformance(int64_t waitTimeUs, int64_t convertTimeUs,
                                         int64_t totalTimeUs)
{
    if (frameCount_ % K_LOG_INTERVAL == 1 || totalTimeUs > K_TOTAL_TIME_THRESHOLD_US) {
        REPLAY_LOG(LOG_INFO,
                   "[PERF] Encode frame=%{public}" PRIu64
                   " wait=%{public}lldus convert=%{public}lldus total=%{public}lldus",
                   frameCount_, static_cast<long long>(waitTimeUs),
                   static_cast<long long>(convertTimeUs), static_cast<long long>(totalTimeUs));
    }
}

bool ReplayEncoder::ValidateEncodeInput(const EncodeInputParams &params, int32_t &realWidth,
                                        int32_t &realHeight, size_t &strideBytes)
{
    if (!params.rgba || params.size == 0) {
        return false;
    }
    realWidth = (params.inputWidth > 0) ? params.inputWidth : width_;
    realHeight = (params.inputHeight > 0) ? params.inputHeight : height_;
    strideBytes = (params.inputStride > 0) ? static_cast<size_t>(params.inputStride)
                                           : (static_cast<size_t>(realWidth) * K_RGBA_CHANNELS);
    return true;
}

bool ReplayEncoder::Encode(const EncodeInputParams &params)
{
    auto encodeStart = std::chrono::steady_clock::now();

    int32_t realWidth = 0;
    int32_t realHeight = 0;
    size_t strideBytes = 0;
    if (!ValidateEncodeInput(params, realWidth, realHeight, strideBytes)) {
        return false;
    }

    InputBufferInfo bufferInfo;
    int64_t waitTimeUs = 0;
    if (!AcquireInputBuffer(bufferInfo, waitTimeUs)) {
        return false;
    }

    auto *dest = static_cast<uint8_t *>(OH_AVBuffer_GetAddr(bufferInfo.buffer));
    if (!dest) {
        REPLAY_LOG(LOG_ERROR, "Encode failed: buffer addr null");
        return false;
    }

    int32_t capacityRet = OH_AVBuffer_GetCapacity(bufferInfo.buffer);
    if (capacityRet > 0) {
        size_t capacitySize = static_cast<size_t>(capacityRet);
        std::fill_n(dest, capacitySize, 0);
    }

    auto convertStart = std::chrono::steady_clock::now();
    const uint8_t *rgbaBytes = static_cast<const uint8_t *>(params.rgba);
    ConvertParams convertParams{rgbaBytes, params.size, dest, static_cast<int32_t>(strideBytes),
                                realWidth, realHeight};
    if (!ConvertRgbaToNv12(convertParams)) {
        REPLAY_LOG(LOG_ERROR, "Encode failed: RGBA->NV12 conversion error");
        return false;
    }
    auto convertTimeUs = std::chrono::duration_cast<std::chrono::microseconds>(
                             std::chrono::steady_clock::now() - convertStart)
                             .count();

    int64_t ptsUs = CalculatePts(params.timestampMs);
    if (!SubmitEncodedFrame(bufferInfo, ptsUs)) {
        return false;
    }

    frameCount_++;
    firstFrame_ = false;
    lastPtsUs_ = ptsUs;

    auto totalTimeUs = std::chrono::duration_cast<std::chrono::microseconds>(
                           std::chrono::steady_clock::now() - encodeStart)
                           .count();
    LogEncodePerformance(waitTimeUs, convertTimeUs, totalTimeUs);
    return true;
}

bool ReplayEncoder::EncodePixelMap(void *pixelMapVoid, int64_t timestampMs)
{
    if (!ready_ || !pixelMapVoid) {
        REPLAY_LOG(LOG_ERROR, "EncodePixelMap: not ready or invalid pixelMap");
        return false;
    }
    NativePixelMap *pixelMap = static_cast<NativePixelMap *>(pixelMapVoid);

    if (!EnsurePixelMapFuncs()) {
        REPLAY_LOG(LOG_ERROR, "EncodePixelMap: symbols not available");
        return false;
    }

    OHOS::Media::OhosPixelMapInfo info;
    int32_t ret = g_getImageInfo(pixelMap, &info);
    if (ret != 0) {
        REPLAY_LOG(LOG_ERROR, "EncodePixelMap: GetImageInfo failed ret=%{public}d", ret);
        return false;
    }

    // Check dimensions
    if (info.width != static_cast<uint32_t>(width_) ||
        info.height != static_cast<uint32_t>(height_)) {
        REPLAY_LOG(LOG_WARN,
                   "EncodePixelMap: dimension mismatch pm=%{public}u x %{public}u "
                   "encoder=%{public}d x %{public}d (auto-padding enabled)",
                   info.width, info.height, width_, height_);
    }

    void *pixels = nullptr;
    ret = g_accessPixels(pixelMap, &pixels);
    if (ret != 0 || !pixels) {
        REPLAY_LOG(LOG_ERROR, "EncodePixelMap: AccessPixels failed ret=%{public}d", ret);
        return false;
    }

    // Pass stride (rowSize) to Encode
    EncodeInputParams params;
    params.rgba = pixels;
    params.size = static_cast<size_t>(info.rowSize * info.height);
    params.timestampMs = timestampMs;
    params.inputStride = static_cast<int32_t>(info.rowSize);
    params.inputWidth = static_cast<int32_t>(info.width);
    params.inputHeight = static_cast<int32_t>(info.height);
    bool result = Encode(params);

    g_unAccessPixels(pixelMap);
    return result;
}

void *ReplayEncoder::GetInputWindow()
{
    return static_cast<void *>(nativeWindow_);
}

void ReplayEncoder::Finalize()
{
    REPLAY_LOG(LOG_INFO, "Finalize begin ready=%{public}d", ready_ ? 1 : 0);
    if (!ready_) {
        REPLAY_LOG(LOG_WARN,
                   "Finalize invoked while encoder not ready. "
                   "frames=%{public}" PRIu64 " samples=%{public}" PRIu64,
                   frameCount_, writtenSamples_);
    }

    if (videoEncoder_ != nullptr) {
        int32_t ret = OH_VideoEncoder_NotifyEndOfStream(videoEncoder_);
        if (ret != AV_ERR_OK) {
            REPLAY_LOG(LOG_WARN, "NotifyEndOfStream failed ret=%{public}d", ret);
        }
    }

    stopRequested_.store(true);
    if (context_) {
        context_->inputCond.notify_all();
        context_->outputCond.notify_all();
    }

    if (drainThread_.joinable()) {
        drainThread_.join();
    }

    bool wasEncoderStarted = encoderStarted_;
    bool wasMuxerStarted = muxerStarted_;

    StopEncoderResources();
    StopMuxerResources();

    REPLAY_LOG(LOG_INFO,
               "Finalize stats frames=%{public}" PRIu64 " samples=%{public}" PRIu64
               " encoderStarted=%{public}d muxerStarted=%{public}d",
               frameCount_, writtenSamples_, wasEncoderStarted ? 1 : 0, wasMuxerStarted ? 1 : 0);
    ResetState();
    REPLAY_LOG(LOG_INFO, "Finalize done");
}

void ReplayEncoder::DrainOutputLoop()
{
    ApplyBackgroundPriority();
    REPLAY_LOG(LOG_INFO, "Output drain thread started");

    while (!stopRequested_.load()) {
        OutputBufferInfo info;
        {
            std::unique_lock<std::mutex> lock(context_->outputMutex);
            context_->outputCond.wait(lock, [this]() {
                return stopRequested_.load() || (context_ && !context_->outputQueue.empty());
            });

            if (stopRequested_.load() && (!context_ || context_->outputQueue.empty())) {
                break;
            }

            if (!context_ || context_->outputQueue.empty()) {
                continue;
            }

            info = context_->outputQueue.front();
            context_->outputQueue.pop();
        }

        if (!ProcessSingleOutputBuffer(info)) {
            break;  // EOS received
        }
    }

    REPLAY_LOG(LOG_INFO,
               "Output drain thread exit stopRequested=%{public}d "
               "writtenSamples=%{public}" PRIu64,
               stopRequested_.load() ? 1 : 0, writtenSamples_);
}

void ReplayEncoder::ApplyBackgroundPriority()
{
#ifdef __OHOS__
    pthread_t thread = pthread_self();
    int policy = 0;
    struct sched_param param;
    if (pthread_getschedparam(thread, &policy, &param) == 0) {
        const int minPriority = sched_get_priority_min(policy);
        if (minPriority != -1 && param.sched_priority != minPriority) {
            param.sched_priority = minPriority;
            pthread_setschedparam(thread, policy, &param);
        }
    }
#endif
}

bool ReplayEncoder::ConvertRgbaToNv12(const ConvertParams &params)
{
    if (!params.rgba || !params.dest) {
        return false;
    }

    int32_t realWidth = (params.inputWidth > 0) ? params.inputWidth : width_;
    int32_t realHeight = (params.inputHeight > 0) ? params.inputHeight : height_;
    size_t strideBytes = (params.inputStride > 0) ? static_cast<size_t>(params.inputStride)
                                                  : (static_cast<size_t>(realWidth) * 4);

    if (yStride_ == 0 || uvStride_ == 0) {
        return false;
    }

    const int32_t copyWidth = std::min(width_, realWidth);
    const int32_t copyHeight = std::min(height_, realHeight);

    uint8_t *yPlane = params.dest;
    uint8_t *uvPlane = params.dest + yPlaneSize_;

    ConvertYPlane(params.rgba, yPlane, copyWidth, copyHeight, strideBytes,
                  static_cast<int32_t>(yStride_));
    ConvertUVPlane(params.rgba, uvPlane, copyWidth, copyHeight, strideBytes,
                   static_cast<int32_t>(uvStride_));

    return true;
}

void ReplayEncoder::HandleCodecError(int32_t errorCode)
{
    REPLAY_LOG(LOG_ERROR, "Codec error callback code=%{public}d", errorCode);
    if (context_) {
        context_->fatalError = true;
    }
}

void ReplayEncoder::HandleFormatChange()
{
    REPLAY_LOG(LOG_INFO, "Codec format changed");
}

void ReplayEncoder::StopEncoderResources()
{
    if (videoEncoder_) {
        REPLAY_LOG(LOG_INFO, "Stopping video encoder");
        OH_VideoEncoder_Flush(videoEncoder_);
        OH_VideoEncoder_Stop(videoEncoder_);
        OH_VideoEncoder_Destroy(videoEncoder_);
        videoEncoder_ = nullptr;
    }
}

void ReplayEncoder::StopMuxerResources()
{
    if (muxer_) {
        REPLAY_LOG(LOG_INFO, "Stopping muxer");
        OH_AVMuxer_Stop(muxer_);
        OH_AVMuxer_Destroy(muxer_);
        muxer_ = nullptr;
    }
}

bool ReplayEncoder::ProcessSingleOutputBuffer(const OutputBufferInfo &info)
{
    if (info.attr.flags & AVCODEC_BUFFER_FLAGS_EOS) {
        REPLAY_LOG(LOG_INFO, "EOS received in output thread");
        return false;
    }

    if (muxer_ && muxerStarted_) {
        int32_t ret = OH_AVMuxer_WriteSampleBuffer(muxer_, videoTrackId_, info.buffer);
        if (ret != AV_ERR_OK) {
            REPLAY_LOG(LOG_ERROR, "WriteSampleBuffer failed ret=%{public}d", ret);
        } else {
            writtenSamples_++;
        }
    }

    if (videoEncoder_) {
        OH_VideoEncoder_FreeOutputBuffer(videoEncoder_, info.index);
    }
    return true;
}

#undef REPLAY_LOG
