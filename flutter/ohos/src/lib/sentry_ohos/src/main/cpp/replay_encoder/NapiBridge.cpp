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

#include <string>
#include <vector>
#include <dlfcn.h>

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

typedef NativePixelMap *(*OhPixelMapInitFunc)(
    napi_env env, napi_value source);

namespace {
constexpr unsigned int BRIDGE_LOG_DOMAIN = 0xD005761;
constexpr const char BRIDGE_LOG_TAG[] =
    "ReplayEncoderNapi";

constexpr size_t K_INIT_ARG_COUNT = 5;
constexpr size_t K_ENCODE_ARG_COUNT = 2;

constexpr size_t ARG_IDX_FD = 0;
constexpr size_t ARG_IDX_WIDTH = 1;
constexpr size_t ARG_IDX_HEIGHT = 2;
constexpr size_t ARG_IDX_FPS = 3;
constexpr size_t ARG_IDX_MIME = 4;

#define BRIDGE_LOG(level, fmt, ...) \
    OH_LOG_Print(LOG_APP, level, BRIDGE_LOG_DOMAIN, \
                 BRIDGE_LOG_TAG, fmt, ##__VA_ARGS__)

std::string GetStringArgument(
    napi_env env, napi_value value)
{
    size_t strLen = 0;
    napi_get_value_string_utf8(
        env, value, nullptr, 0, &strLen);
    if (strLen == 0) {
        return std::string();
    }
    std::vector<char> buffer(strLen + 1, '\0');
    napi_get_value_string_utf8(
        env, value, buffer.data(),
        buffer.size(), &strLen);
    return std::string(buffer.data(), strLen);
}

OhPixelMapInitFunc LoadPixelMapInitFunc()
{
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
        void *h = dlopen(libName, RTLD_LAZY);
        if (!h) {
            continue;
        }
        for (const char *symName : syms) {
            auto fn =
                reinterpret_cast<OhPixelMapInitFunc>(
                    dlsym(h, symName));
            if (fn) {
                return fn;
            }
        }
    }
    BRIDGE_LOG(LOG_ERROR,
        "LoadPixelMapInitFunc: not found");
    return nullptr;
}

napi_value InitBridge(
    napi_env env, napi_callback_info info)
{
    size_t argc = K_INIT_ARG_COUNT;
    napi_value args[K_INIT_ARG_COUNT] = {nullptr};
    napi_get_cb_info(
        env, info, &argc, args, nullptr, nullptr);
    if (argc < K_INIT_ARG_COUNT) {
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }
    int32_t fd = -1;
    int32_t width = 0;
    int32_t height = 0;
    int32_t fps = 0;
    napi_get_value_int32(
        env, args[ARG_IDX_FD], &fd);
    napi_get_value_int32(
        env, args[ARG_IDX_WIDTH], &width);
    napi_get_value_int32(
        env, args[ARG_IDX_HEIGHT], &height);
    napi_get_value_int32(
        env, args[ARG_IDX_FPS], &fps);
    std::string mime =
        GetStringArgument(env, args[ARG_IDX_MIME]);
    bool ok = ReplayEncoder::Instance().Init(
        fd, width, height, fps, mime);
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

napi_value EncodeBridge(
    napi_env env, napi_callback_info info)
{
    size_t argc = K_ENCODE_ARG_COUNT;
    napi_value args[K_ENCODE_ARG_COUNT] = {nullptr};
    napi_get_cb_info(
        env, info, &argc, args, nullptr, nullptr);
    if (argc < K_ENCODE_ARG_COUNT) {
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }
    void *data = nullptr;
    size_t length = 0;
    napi_get_arraybuffer_info(
        env, args[0], &data, &length);
    int64_t timestamp = 0;
    napi_get_value_int64(env, args[1], &timestamp);
    bool ok = ReplayEncoder::Instance().Encode(
        data, length, timestamp);
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

napi_value EncodePixelMapBridge(
    napi_env env, napi_callback_info info)
{
    size_t argc = K_ENCODE_ARG_COUNT;
    napi_value args[K_ENCODE_ARG_COUNT] = {nullptr};
    napi_get_cb_info(
        env, info, &argc, args, nullptr, nullptr);
    if (argc < K_ENCODE_ARG_COUNT) {
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }
    static OhPixelMapInitFunc initFunc = nullptr;
    if (!initFunc) {
        initFunc = LoadPixelMapInitFunc();
    }
    if (!initFunc) {
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }
    void *nativePm = initFunc(env, args[0]);
    if (!nativePm) {
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }
    int64_t timestamp = 0;
    napi_get_value_int64(env, args[1], &timestamp);
    bool ok = ReplayEncoder::Instance().EncodePixelMap(
        nativePm, timestamp);
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

napi_value GetInputWindowBridge(
    napi_env env, napi_callback_info info)
{
    (void)info;
    void *window =
        ReplayEncoder::Instance().GetInputWindow();
    napi_value result;
    if (window) {
        napi_create_bigint_uint64(
            env,
            reinterpret_cast<uint64_t>(window),
            &result);
    } else {
        napi_get_undefined(env, &result);
    }
    return result;
}

napi_value FinalizeBridge(
    napi_env env, napi_callback_info info)
{
    (void)info;
    ReplayEncoder::Instance().Finalize();
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

} // namespace

EXTERN_C_START
static napi_value Register(
    napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"init", nullptr, InitBridge,
         nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"encode", nullptr, EncodeBridge,
         nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"encodePixelMap", nullptr,
         EncodePixelMapBridge,
         nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"getInputWindow", nullptr,
         GetInputWindowBridge,
         nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"finalize", nullptr, FinalizeBridge,
         nullptr, nullptr, nullptr,
         napi_default, nullptr},
    };
    napi_define_properties(
        env, exports,
        sizeof(descriptors) / sizeof(descriptors[0]),
        descriptors);
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
