# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(ndk)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# Load sentry-native repo and version from config
# flutter/ohos/src/main/cpp/CMakeLists.txt -> flutter/sentry-native/CMakeCache.txt
set(SENTRY_NATIVE_CONFIG ${CMAKE_SOURCE_DIR}/../../../../../sentry-native)
load_cache("${SENTRY_NATIVE_CONFIG}" READ_WITH_PREFIX SENTRY_NATIVE_ repo version)
message(STATUS "Fetching Sentry native version: ${SENTRY_NATIVE_version} from ${SENTRY_NATIVE_repo}")

# Use FetchContent to download sentry-native from remote repository
include(FetchContent)
FetchContent_Declare(
    sentry-native
    GIT_REPOSITORY ${SENTRY_NATIVE_repo}
    GIT_TAG ${SENTRY_NATIVE_version}
)

# Populate first to get source dir before add_subdirectory
FetchContent_GetProperties(sentry-native)
if(NOT sentry-native_POPULATED)
    FetchContent_Populate(sentry-native)
endif()

if (NOT THIRDPARTY_DIR)
    set(THIRDPARTY_DIR "${sentry-native_SOURCE_DIR}/external/external/third_party")
endif()

# Adding sentry-native project from fetched source
add_subdirectory(${sentry-native_SOURCE_DIR} ${sentry-native_BINARY_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
        ${NATIVERENDER_ROOT_PATH}/include)

add_library(entry SHARED ndk_sample.cpp)
target_link_libraries(entry PUBLIC libace_napi.z.so $<BUILD_INTERFACE:sentry::sentry>)

