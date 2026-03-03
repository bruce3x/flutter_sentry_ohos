# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(ndk)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# Load sentry-native repo and version from config
# flutter/example/ohos/entry/src/main/cpp -> flutter/sentry-native/CMakeCache.txt
set(SENTRY_NATIVE_CONFIG ${CMAKE_SOURCE_DIR}/../../../../../../sentry-native)
load_cache("${SENTRY_NATIVE_CONFIG}" READ_WITH_PREFIX SENTRY_NATIVE_ repo version)
message(STATUS "Fetching Sentry native headers version: ${SENTRY_NATIVE_version} from ${SENTRY_NATIVE_repo}")

# Use FetchContent to download sentry-native headers from remote repository
include(FetchContent)
FetchContent_Declare(
    sentry-native
    GIT_REPOSITORY ${SENTRY_NATIVE_repo}
    GIT_TAG ${SENTRY_NATIVE_version}
    EXCLUDE_FROM_ALL
)

FetchContent_GetProperties(sentry-native)
if(NOT sentry-native_POPULATED)
    FetchContent_Populate(sentry-native)
endif()

# Path to prebuilt library in oh_modules
# This assumes the build is for arm64-v8a. For a more generic solution, we might need to detect abi.
# CMAKE_SOURCE_DIR is entry/src/main/cpp
set(SENTRY_LIB_PATH ${CMAKE_SOURCE_DIR}/../../../oh_modules/@ohos/sentry_native/libs/arm64-v8a/libsentry.so)

include_directories(${NATIVERENDER_ROOT_PATH}
        ${NATIVERENDER_ROOT_PATH}/include
        ${sentry-native_SOURCE_DIR}/include)

# Import the existing library from HAR
add_library(sentry SHARED IMPORTED)
set_target_properties(sentry PROPERTIES IMPORTED_LOCATION ${SENTRY_LIB_PATH})

add_library(entry SHARED ndk_sample.cpp)

# Link against the imported sentry library
target_link_libraries(entry PUBLIC libace_napi.z.so libhilog_ndk.z.so sentry)

