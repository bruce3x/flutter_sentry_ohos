# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(ndk)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
set(SENTRY_NATIVE_SRC ${CMAKE_SOURCE_DIR}/../../../../../sentry-native)
# flutter/ohos/src/main/cpp/CMakeLists.txt
# flutter/sentry-native
if (NOT THIRDPARTY_DIR)
	set(THIRDPARTY_DIR "${SENTRY_NATIVE_SRC}/external/external/third_party")
endif()

# Adding sentry-native project
add_subdirectory(${SENTRY_NATIVE_SRC} sentry_build)

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

add_library(entry SHARED ndk_sample.cpp)
target_link_libraries(entry PUBLIC libace_napi.z.so $<BUILD_INTERFACE:sentry::sentry>)

