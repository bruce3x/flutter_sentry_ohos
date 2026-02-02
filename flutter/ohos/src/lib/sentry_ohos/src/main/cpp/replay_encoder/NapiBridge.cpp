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

#include <dlfcn.h>

#include <string>
#include <vector>

#include "ReplayEncoder.h"
#include "hilog/log.h"
#include "napi/native_api.h"

#ifndef EXTERN_C_START
#ifdef __cplusplus
#define EXTERN_C_START extern "C" {
#define EXTERN_C_END }
#else
#define EXTERN_C_START
#define EXTERN_C_END
#endif
#endif

// Manual declaration of the NAPI interop function.
// This function is exported by libpixelmap.z.so (OpenHarmony API 12+).
// We declare it here to avoid header dependency issues.
extern "C" NativePixelMap *OH_PixelMap_InitNativePixelMap(napi_env env, napi_value source);

typedef NativePixelMap *(*OhPixelMapInitNativePixelMapFunc)(napi_env env, napi_value source);

namespace
{
constexpr unsigned int BRIDGE_LOG_DOMAIN = 0xD005761;
constexpr const char BRIDGE_LOG_TAG[] = "ReplayEncoderNapi";

// 参数索引常量
constexpr int K_ARG_INDEX_FD = 0;
constexpr int K_ARG_INDEX_WIDTH = 1;
constexpr int K_ARG_INDEX_HEIGHT = 2;
constexpr int K_ARG_INDEX_FPS = 3;
constexpr int K_ARG_INDEX_MIME = 4;
constexpr int K_ARG_INDEX_DATA = 0;
constexpr int K_ARG_INDEX_TIMESTAMP = 1;

#define BRIDGE_LOG(level, fmt, ...) \
    OH_LOG_Print(LOG_APP, level, BRIDGE_LOG_DOMAIN, BRIDGE_LOG_TAG, fmt, ##__VA_ARGS__)

std::string GetStringArgument(napi_env env, napi_value value)
{
    size_t strLen = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &strLen);
    if (strLen == 0) {
        return std::string();
    }
    std::vector<char> buffer(strLen + 1, '\0');
    napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &strLen);
    return std::string(buffer.data(), strLen);
}

napi_value InitBridge(napi_env env, napi_callback_info info)
{
    constexpr size_t kRequiredArgCount = 5;
    size_t argc = kRequiredArgCount;
    napi_value args[kRequiredArgCount] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < kRequiredArgCount) {
        BRIDGE_LOG(LOG_ERROR, "init: insufficient args %{public}zu", argc);
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }

    int32_t fd = -1;
    int32_t width = 0;
    int32_t height = 0;
    int32_t fps = 0;
    napi_get_value_int32(env, args[K_ARG_INDEX_FD], &fd);
    napi_get_value_int32(env, args[K_ARG_INDEX_WIDTH], &width);
    napi_get_value_int32(env, args[K_ARG_INDEX_HEIGHT], &height);
    napi_get_value_int32(env, args[K_ARG_INDEX_FPS], &fps);
    std::string mime = GetStringArgument(env, args[K_ARG_INDEX_MIME]);

    BRIDGE_LOG(LOG_INFO,
               "native init fd=%{public}d width=%{public}d height=%{public}d "
               "fps=%{public}d mime=%{public}s",
               fd, width, height, fps, mime.c_str());

    bool ok = ReplayEncoder::Instance().Init(fd, width, height, fps, mime);
    BRIDGE_LOG(ok ? LOG_INFO : LOG_ERROR, "native init result ok=%{public}d", ok ? 1 : 0);

    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

napi_value EncodeBridge(napi_env env, napi_callback_info info)
{
    constexpr size_t kRequiredArgCount = 2;
    size_t argc = kRequiredArgCount;
    napi_value args[kRequiredArgCount] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < kRequiredArgCount) {
        BRIDGE_LOG(LOG_ERROR, "encode: insufficient args %{public}zu", argc);
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }

    void *data = nullptr;
    size_t length = 0;
    napi_get_arraybuffer_info(env, args[K_ARG_INDEX_DATA], &data, &length);

    int64_t timestamp = 0;
    napi_get_value_int64(env, args[K_ARG_INDEX_TIMESTAMP], &timestamp);
    BRIDGE_LOG(LOG_INFO, "encode: len=%{public}zu ts=%{public}lld", length,
               static_cast<long long>(timestamp));

    EncodeInputParams params;
    params.rgba = data;
    params.size = length;
    params.timestampMs = timestamp;
    bool ok = ReplayEncoder::Instance().Encode(params);
    BRIDGE_LOG(ok ? LOG_INFO : LOG_ERROR, "encode result ok=%{public}d", ok ? 1 : 0);
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

napi_value EncodePixelMapBridge(napi_env env, napi_callback_info info)
{
    constexpr size_t kRequiredArgCount = 2;
    size_t argc = kRequiredArgCount;
    napi_value args[kRequiredArgCount] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < kRequiredArgCount) {
        BRIDGE_LOG(LOG_ERROR, "encodePixelMap: insufficient args %{public}zu", argc);
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }

    static OhPixelMapInitNativePixelMapFunc initFunc = nullptr;
    if (!initFunc) {
        const char *libs[] = {
            "libpixelmap.z.so",
            "libimage_ndk.z.so",
            "libpixelmap_ndk.z.so",
        };
        const char *syms[] = {
            "OH_PixelMap_InitNativePixelMap",
            "OH_Image_InitNativePixelMap",
        };

        for (const char *libName : libs) {
            void *handle = dlopen(libName, RTLD_LAZY);
            if (handle) {
                BRIDGE_LOG(LOG_INFO, "dlopen success: %{public}s", libName);
                for (const char *symName : syms) {
                    initFunc = (OhPixelMapInitNativePixelMapFunc)dlsym(handle, symName);
                    if (initFunc) {
                        BRIDGE_LOG(LOG_INFO, "dlsym success: %{public}s in %{public}s", symName,
                                   libName);
                        break;
                    }
                }
            } else {
                BRIDGE_LOG(LOG_DEBUG, "dlopen failed: %{public}s", libName);
            }
            if (initFunc)
                break;
        }

        if (!initFunc) {
            BRIDGE_LOG(LOG_ERROR,
                       "encodePixelMap: failed to find OH_PixelMap_InitNativePixelMap in any known "
                       "library");
            napi_value result;
            napi_get_boolean(env, false, &result);
            return result;
        }
    }

    void *nativePm = initFunc(env, args[K_ARG_INDEX_DATA]);
    if (!nativePm) {
        BRIDGE_LOG(LOG_ERROR, "encodePixelMap: failed to unwrap NativePixelMap");
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }

    int64_t timestamp = 0;
    napi_get_value_int64(env, args[K_ARG_INDEX_TIMESTAMP], &timestamp);
    BRIDGE_LOG(LOG_INFO, "encodePixelMap: ts=%{public}lld", static_cast<long long>(timestamp));

    bool ok = ReplayEncoder::Instance().EncodePixelMap(nativePm, timestamp);
    BRIDGE_LOG(ok ? LOG_INFO : LOG_ERROR, "encodePixelMap result ok=%{public}d", ok ? 1 : 0);

    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

napi_value GetInputWindowBridge(napi_env env, napi_callback_info info)
{
    (void)info;
    void *window = ReplayEncoder::Instance().GetInputWindow();
    napi_value result;
    if (window) {
        napi_create_bigint_uint64(env, reinterpret_cast<uint64_t>(window), &result);
    } else {
        napi_get_undefined(env, &result);
    }
    return result;
}

napi_value FinalizeBridge(napi_env env, napi_callback_info info)
{
    (void)info;
    BRIDGE_LOG(LOG_INFO, "finalize: called");
    ReplayEncoder::Instance().Finalize();
    BRIDGE_LOG(LOG_INFO, "finalize: done");
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

}  // namespace

EXTERN_C_START
static napi_value Register(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"init", nullptr, InitBridge, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"encode", nullptr, EncodeBridge, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"encodePixelMap", nullptr, EncodePixelMapBridge, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"getInputWindow", nullptr, GetInputWindowBridge, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"finalize", nullptr, FinalizeBridge, nullptr, nullptr, nullptr, napi_default, nullptr},
    };

    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}
EXTERN_C_END

static napi_module g_replayEncoderModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Register,
    .nm_modname = "replay_encoder",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterReplayEncoderModule()
{
    napi_module_register(&g_replayEncoderModule);
}

#undef BRIDGE_LOG
