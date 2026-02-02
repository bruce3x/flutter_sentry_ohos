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

#include "napi/native_api.h"
#include <hilog/log.h>

#define TAG "napi-sample"

extern "C" {
static napi_value crash(napi_env env, napi_callback_info info)
{
    OH_LOG_Print(LOG_APP, LOG_DEBUG, LOG_DOMAIN, TAG, "About to crash.");
    char *ptr = nullptr;
    *ptr += 1;
    return nullptr;
}

static napi_value message(napi_env env, napi_callback_info info)
{
    OH_LOG_Print(LOG_APP, LOG_DEBUG, LOG_DOMAIN, TAG,
        "Sending message (sentry disabled).");
    bool success = true;
    napi_value result;
    napi_get_boolean(env, success, &result);
    return result;
}

napi_value transaction(napi_env env, napi_callback_info info)
{
    OH_LOG_Print(LOG_APP, LOG_DEBUG, LOG_DOMAIN, TAG,
        "Sending transaction (sentry disabled).");
    bool success = true;
    napi_value result;
    napi_get_boolean(env, success, &result);
    return result;
}
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"crash", nullptr, crash, nullptr, nullptr, nullptr, napi_default,
            nullptr},
        {"message", nullptr, message, nullptr, nullptr, nullptr, napi_default,
            nullptr},
        {"transaction", nullptr, transaction, nullptr, nullptr, nullptr,
            napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void)
{
    napi_module_register(&demoModule);
}
