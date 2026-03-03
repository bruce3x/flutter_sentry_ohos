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
#include <sentry.h>

#define TAG "ndk-sample"
#define LOG_DOMAIN 0x0000

namespace {
constexpr int32_t K_TEST_SAMPLE_VALUE = 42;
} // namespace

extern "C" {
static napi_value crash(
    napi_env env, napi_callback_info info)
{
    OH_LOG_Print(LOG_APP, LOG_DEBUG, LOG_DOMAIN, TAG,
                 "About to crash.");
    char *ptr = nullptr;
    *ptr += 1;
    return nullptr;
}

static napi_value message(
    napi_env env, napi_callback_info info)
{
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, TAG,
                 "Sending message (sentry enabled).");
    sentry_value_t event =
        sentry_value_new_message_event(
            SENTRY_LEVEL_INFO, "custom",
            "Native Exception");
    sentry_uuid_s uuid =
        sentry_capture_event(event);
    bool success = !sentry_uuid_is_nil(&uuid);
    if (success) {
        OH_LOG_Print(
            LOG_APP, LOG_INFO, LOG_DOMAIN, TAG,
            "Sentry native capture success.");
    } else {
        OH_LOG_Print(
            LOG_APP, LOG_ERROR, LOG_DOMAIN, TAG,
            "Sentry native capture failed.");
    }
    napi_value result;
    napi_get_boolean(env, success, &result);
    return result;
}

napi_value transaction(
    napi_env env, napi_callback_info info)
{
    OH_LOG_Print(LOG_APP, LOG_DEBUG, LOG_DOMAIN, TAG,
                 "Sending transaction.");
    sentry_transaction_context_t *txCtx =
        sentry_transaction_context_new(
            "little.teapot",
            "Short and stout here is my handle"
            " and here is my spout");
    sentry_value_t customSamplingCtx =
        sentry_value_new_object();
    sentry_value_set_by_key(
        customSamplingCtx, "b",
        sentry_value_new_int32(K_TEST_SAMPLE_VALUE));
    sentry_transaction_t *tx =
        sentry_transaction_start(
            txCtx, customSamplingCtx);
    sentry_transaction_set_data(
        tx, "url",
        sentry_value_new_string(
            "https://example.com"));
    sentry_span_t *child =
        sentry_transaction_start_child(
            tx, "littler.teapot", nullptr);
    sentry_span_t *grandchild =
        sentry_span_start_child(
            child, "littlest.teapot", nullptr);
    sentry_span_set_data(
        child, "span_data_says",
        sentry_value_new_string("hi!"));
    sentry_span_finish(grandchild);
    sentry_span_finish(child);
    sentry_uuid_s uuid =
        sentry_transaction_finish(tx);
    bool success = false;
    if (sentry_uuid_is_nil(&uuid)) {
        success = true;
        OH_LOG_Print(
            LOG_APP, LOG_DEBUG, LOG_DOMAIN, TAG,
            "Transaction was not sent.");
    } else {
        success = false;
        OH_LOG_Print(
            LOG_APP, LOG_DEBUG, LOG_DOMAIN, TAG,
            "Transaction sent.");
    }
    napi_value result;
    napi_get_boolean(env, success, &result);
    return result;
}
}

EXTERN_C_START
static napi_value Init(
    napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"crash", nullptr, crash,
         nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"message", nullptr, message,
         nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"transaction", nullptr, transaction,
         nullptr, nullptr, nullptr,
         napi_default, nullptr}
    };
    napi_define_properties(
        env, exports,
        sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void)
{
    napi_module_register(&demoModule);
}
