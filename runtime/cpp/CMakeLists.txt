# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(ArkLauncherPro)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

add_library(main SHARED globals.h main.c paths.c jvm.c game.c plan.c napi_init.c)
target_compile_definitions(main PRIVATE _GNU_SOURCE)

add_subdirectory("SDL")
target_link_libraries(main PUBLIC SDL3::SDL3 dl hilog_ndk.z ability_runtime ace_napi.z)