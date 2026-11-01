# This file is a part of media_kit (https://gh-proxy.com/https://github.com/media-kit/media-kit).
#
# Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
# All rights reserved.
# Use of this source code is governed by MIT license that can be found in the LICENSE file.

cmake_minimum_required(VERSION 3.14)

# This option is read by the other packages which are part of package:media_kit.
option(MEDIA_KIT_LIBS_AVAILABLE "package:media_kit libraries are available." ON)

set(PROJECT_NAME "media_kit_libs_windows_video")
project(${PROJECT_NAME} LANGUAGES CXX)

# Deal with MSVC incompatiblity
add_compile_definitions(_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR)

# ------------------------------------------------------------------------------
function(download_and_verify url md5 locationForArchive)
  # Check if the archive exists.
  if(EXISTS "${locationForArchive}")
    file(MD5 "${locationForArchive}" ARCHIVE_MD5)

    # If MD5 doesn't match, delete the archive to download again.
    if(NOT md5 STREQUAL ARCHIVE_MD5)
      file(REMOVE "${locationForArchive}")
      message(STATUS "MD5 mismatch. File deleted.")
    endif()
  endif()

  # Download the archive if it doesn't exist.
  if(NOT EXISTS "${locationForArchive}")
    message(STATUS "Downloading archive from ${url}...")
    file(DOWNLOAD "${url}" "${locationForArchive}"
      STATUS download_status TIMEOUT 180 INACTIVITY_TIMEOUT 30 TLS_VERIFY ON)
    list(GET download_status 0 download_code)
    if(NOT download_code EQUAL 0)
      message(FATAL_ERROR "Archive download failed (${download_status}). Run tool/prepare-windows-media.ps1 to populate the verified cache.")
    endif()
    message(STATUS "Downloaded archive to ${locationForArchive}.")

    # Verify MD5 of the newly downloaded file.
    file(MD5 "${locationForArchive}" ARCHIVE_MD5)

    if(md5 STREQUAL ARCHIVE_MD5)
      message(STATUS "${locationForArchive} Verification successful.")
    else()
      message(FATAL_ERROR "${locationForArchive} Integrity check failed, please try to re-build project again.")
    endif()
  endif()
endfunction()

function(extract_archive_if_incomplete archive destination)
  set(complete TRUE)
  foreach(required IN LISTS ARGN)
    if(NOT EXISTS "${destination}/${required}")
      set(complete FALSE)
    endif()
  endforeach()
  if(NOT complete)
    file(MAKE_DIRECTORY "${destination}")
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -E tar xf "${archive}"
      WORKING_DIRECTORY "${destination}"
      RESULT_VARIABLE extract_result
      OUTPUT_QUIET
      ERROR_VARIABLE extract_error
    )
    if(NOT "${extract_result}" STREQUAL "0")
      message(FATAL_ERROR "Cannot extract ${archive}: ${extract_error}")
    endif()
  endif()
  foreach(required IN LISTS ARGN)
    if(NOT EXISTS "${destination}/${required}")
      message(FATAL_ERROR "Incomplete native dependency: ${destination}/${required}")
    endif()
  endforeach()
endfunction()

if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64")
  # ARM64 archives and MSVC import libraries are prepared by the build script.
  # The x64 runtime keeps its original dependency pins below.
  set(LIBMPV_SRC "${CMAKE_BINARY_DIR}/libmpv-20261021")
  set(ANGLE_SRC "${CMAKE_BINARY_DIR}/ANGLE")
  foreach(required
      "${LIBMPV_SRC}/libmpv-2.dll"
      "${CMAKE_BINARY_DIR}/libmpv/libmpv.dll.a"
      "${CMAKE_BINARY_DIR}/libmpv/include/client.h"
      "${ANGLE_SRC}/libEGL.dll"
      "${ANGLE_SRC}/libGLESv2.dll"
      "${ANGLE_SRC}/d3dcompiler_47.dll"
      "${ANGLE_SRC}/vk_swiftshader.dll"
      "${ANGLE_SRC}/vulkan-1.dll"
      "${ANGLE_SRC}/include/EGL/egl.h"
      "${ANGLE_SRC}/lib/libEGL.dll.lib"
      "${ANGLE_SRC}/lib/libGLESv2.dll.lib")
    if(NOT EXISTS "${required}")
      message(FATAL_ERROR "Missing ARM64 dependency ${required}. Run tool/prepare-windows-media.ps1 -Architecture arm64.")
    endif()
  endforeach()
else()
# libmpv archive containing the pre-built shared libraries & headers.
set(LIBMPV "mpv-dev-x86_64-20241021-git-0f78584.7z")

# Download URL & MD5 hash of the libmpv archive.
set(LIBMPV_URL "https://gh-proxy.com/https://github.com/media-kit/libmpv-win32-video-cmake/releases/download/20241021/${LIBMPV}")
set(LIBMPV_MD5 "6ecf18e85b093c3f7edb16f3ee6603f3")
set(LIBMPV_SHA256 "e23701df0adc1fe57c8ede3ff313513b0b80519870058c2d35ff02754284a007")

# Download location of the libmpv archive.
set(LIBMPV_ARCHIVE "${CMAKE_BINARY_DIR}/${LIBMPV}")
set(LIBMPV_SRC "${CMAKE_BINARY_DIR}/libmpv-20241021")

download_and_verify(
  ${LIBMPV_URL}
  ${LIBMPV_MD5}
  ${LIBMPV_ARCHIVE}
)
file(SHA256 "${LIBMPV_ARCHIVE}" ARCHIVE_SHA256)
if(NOT ARCHIVE_SHA256 STREQUAL LIBMPV_SHA256)
  message(FATAL_ERROR "libmpv SHA-256 verification failed.")
endif()

# Complete extraction during configuration, before media_kit_video can compile.
extract_archive_if_incomplete("${LIBMPV_ARCHIVE}" "${LIBMPV_SRC}"
  libmpv-2.dll libmpv.dll.a
  include/mpv/client.h include/mpv/render.h include/mpv/render_gl.h include/mpv/stream_cb.h)

# The Dart video package consumes this stable include/import-library layout.
# Publish both from the same pin as the DLL bundled below.
set(LIBMPV_BUILD_INTERFACE "${CMAKE_BINARY_DIR}/libmpv")
file(MAKE_DIRECTORY "${LIBMPV_BUILD_INTERFACE}/include")
file(COPY "${LIBMPV_SRC}/include/mpv/" DESTINATION "${LIBMPV_BUILD_INTERFACE}/include")
file(COPY "${LIBMPV_SRC}/libmpv.dll.a" DESTINATION "${LIBMPV_BUILD_INTERFACE}")

# ------------------------------------------------------------------------------

# ANGLE archive containing the pre-built shared libraries & headers.
set(ANGLE "ANGLE.7z")

# Download URL & MD5 hash of the ANGLE archive.
set(ANGLE_URL "https://gh-proxy.com/https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z")
set(ANGLE_MD5 "e866f13e8d552348058afaafe869b1ed")

# Download location of the ANGLE archive.
set(ANGLE_ARCHIVE "${CMAKE_BINARY_DIR}/${ANGLE}")
set(ANGLE_SRC "${CMAKE_BINARY_DIR}/ANGLE")

download_and_verify(
  ${ANGLE_URL}
  ${ANGLE_MD5}
  ${ANGLE_ARCHIVE}
)

extract_archive_if_incomplete("${ANGLE_ARCHIVE}" "${ANGLE_SRC}"
  d3dcompiler_47.dll libEGL.dll libGLESv2.dll vk_swiftshader.dll vulkan-1.dll
  include/EGL/egl.h lib/libEGL.dll.lib lib/libGLESv2.dll.lib)
endif()

# ------------------------------------------------------------------------------
set(PLUGIN_NAME "media_kit_libs_windows_video_plugin")

add_library(
  ${PLUGIN_NAME} SHARED
  "include/media_kit_libs_windows_video/media_kit_libs_windows_video_plugin_c_api.h"
  "media_kit_libs_windows_video_plugin_c_api.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(
  ${PLUGIN_NAME}
  PROPERTIES
  CXX_VISIBILITY_PRESET
  hidden
)
target_compile_definitions(
  ${PLUGIN_NAME}
  PRIVATE
  FLUTTER_PLUGIN_IMPL
)

target_include_directories(
  ${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(
  ${PLUGIN_NAME}
  PRIVATE
  flutter
  flutter_wrapper_plugin
)

set(
  media_kit_libs_windows_video_bundled_libraries
  "${LIBMPV_SRC}/libmpv-2.dll"
  "${ANGLE_SRC}/d3dcompiler_47.dll"
  "${ANGLE_SRC}/libEGL.dll"
  "${ANGLE_SRC}/libGLESv2.dll"
  "${ANGLE_SRC}/vk_swiftshader.dll"
  "${ANGLE_SRC}/vulkan-1.dll"
  # The archive's zlib.dll uses debug CRTs and is not imported by these binaries.
  PARENT_SCOPE
)
