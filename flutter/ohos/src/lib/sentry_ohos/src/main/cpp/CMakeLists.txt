cmake_minimum_required(VERSION 3.5)
project(replay_encoder)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(REPLAY_ENCODER_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/replay_encoder)

add_library(replay_encoder SHARED
    ${REPLAY_ENCODER_SRC_DIR}/ReplayEncoder.cpp
    ${REPLAY_ENCODER_SRC_DIR}/NapiBridge.cpp
)

target_include_directories(replay_encoder PRIVATE
    ${REPLAY_ENCODER_SRC_DIR}
)

target_compile_definitions(replay_encoder PRIVATE
    OHOS_PLATFORM
    __OHOS__
)

target_link_libraries(replay_encoder PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_media_codecbase.so
    libnative_media_core.so
    libnative_media_venc.so
    libnative_media_avmuxer.so
    libnative_media_avsource.so
    libnative_media_avdemuxer.so
    libnative_window.so
    libnative_buffer.so
)


