# Builds markitdown_whisper — the mdw layer (mdw.h) — together with
# whisper.cpp, ggml, and libopus. Launched from whisper/build.sh, which
# also passes the paths to the sources (-DMDW_*_DIR).
#
# Output in ${CMAKE_BINARY_DIR}/bin (the same place whisper.cpp itself
# writes to) — everything that ships with the app:
#   markitdown_whisper  — our layer (miniaudio, libopus statically linked in)
#   whisper, ggml, ggml-base — shared: the CPU backend variants below link
#                         against ggml-base and aren't possible without a
#                         shared build
#   ggml-cpu-<variant>  — a CPU backend for different instruction sets
#                         (SSE4.2, AVX2, AVX-512… / armv8.0 … armv9.2); at
#                         runtime ggml picks the best one the processor
#                         can handle
#
# Why variants instead of a single build: under AVX2 the app crashes
# entirely ("illegal instruction") on a processor without AVX2 — and
# that's still Pentium/Celeron as of the 2020s; under plain SSE it's
# several times slower on everything else.
cmake_minimum_required(VERSION 3.16)
project(markitdown_whisper C CXX)
# whisper.cpp declares a cmake_minimum_required newer than 3.13, and
# without this its option(BUILD_SHARED_LIBS …) overwrites the value set
# here.
set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)

set(MDW_WHISPER_DIR "" CACHE PATH "исходники whisper.cpp")
set(MDW_MINIAUDIO_DIR "" CACHE PATH "исходники miniaudio")
set(MDW_OPUS_DIR "" CACHE PATH "исходники libopus")
foreach(dir MDW_WHISPER_DIR MDW_MINIAUDIO_DIR MDW_OPUS_DIR)
  if(NOT EXISTS "${${dir}}")
    message(FATAL_ERROR "${dir} не задан или не существует: '${${dir}}'")
  endif()
endforeach()

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
# The directory is moved as a whole: libraries look for their neighbors right next to themselves.
if(APPLE)
  set(CMAKE_INSTALL_NAME_DIR "@rpath")
  set(CMAKE_BUILD_RPATH "@loader_path")
  set(CMAKE_BUILD_WITH_INSTALL_NAME_DIR ON)
elseif(UNIX)
  set(CMAKE_BUILD_RPATH "\$ORIGIN")
endif()

# --- libopus: statically linked into markitdown_whisper. Added BEFORE
# whisper.cpp: a global BUILD_SHARED_LIBS=ON would make it shared.
set(BUILD_SHARED_LIBS OFF)
set(OPUS_BUILD_SHARED_LIBRARY OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
# Opus 1.5+ neural extensions (packet-loss recovery, speech enhancement) —
# not needed for decoding a file without packet loss, and they weigh
# megabytes.
set(OPUS_DRED OFF CACHE BOOL "" FORCE)
set(OPUS_OSCE OFF CACHE BOOL "" FORCE)
add_subdirectory("${MDW_OPUS_DIR}" opus EXCLUDE_FROM_ALL)

# --- whisper.cpp + ggml ---
set(BUILD_SHARED_LIBS ON)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(WHISPER_CURL OFF CACHE BOOL "" FORCE)   # downloading the model by URL — no
set(WHISPER_SDL2 OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)    # not for the build machine's own processor
set(GGML_BACKEND_DL ON CACHE BOOL "" FORCE)
set(GGML_CPU_ALL_VARIANTS ON CACHE BOOL "" FORCE)
# ggml's own thread pool instead of OpenMP: otherwise Windows needs
# vcomp140.dll, which the user may not have, and Android needs libomp.so.
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_RPC OFF CACHE BOOL "" FORCE)       # networked backend — no
set(GGML_METAL OFF CACHE BOOL "" FORCE)     # CPU only, the same everywhere
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
set(GGML_CCACHE OFF CACHE BOOL "" FORCE)
add_subdirectory("${MDW_WHISPER_DIR}" whisper EXCLUDE_FROM_ALL)

add_library(markitdown_whisper SHARED
  mdw.c
  mdw_decode.c
  mdw_platform_android.c
  mdw_platform_windows.cpp
)
target_include_directories(markitdown_whisper PRIVATE "${MDW_MINIAUDIO_DIR}")
target_link_libraries(markitdown_whisper PRIVATE whisper ggml opus)
set_target_properties(markitdown_whisper PROPERTIES
  C_STANDARD 11
  CXX_STANDARD 17
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
)
if(ANDROID)
  target_link_libraries(markitdown_whisper PRIVATE mediandk log)
elseif(WIN32)
  # mfplat/mfreadwrite — not here: they're loaded dynamically
  # (mdw_platform_windows.cpp); mfuuid is just GUIDs, a static library.
  target_link_libraries(markitdown_whisper PRIVATE mfuuid ole32)
  # miniaudio and stb_vorbis call fopen/strcpy — MSVC's warnings about
  # "unsafe" functions don't apply to us.
  target_compile_definitions(markitdown_whisper PRIVATE _CRT_SECURE_NO_WARNINGS)
else()
  target_link_libraries(markitdown_whisper PRIVATE m)
endif()

# CPU backend variants are MODULE libraries that whisper doesn't depend
# on: without an explicit dependency, `--target markitdown_whisper` wouldn't build them.
get_property(GGML_TARGETS DIRECTORY "${MDW_WHISPER_DIR}/ggml/src"
  PROPERTY BUILDSYSTEM_TARGETS)
set(MDW_CPU_VARIANTS "")
foreach(target ${GGML_TARGETS})
  if(target MATCHES "^ggml-cpu-")
    list(APPEND MDW_CPU_VARIANTS ${target})
  endif()
endforeach()
if(NOT MDW_CPU_VARIANTS)
  message(FATAL_ERROR "не нашёл ни одного варианта ggml-cpu-* — проверить GGML_CPU_ALL_VARIANTS")
endif()
message(STATUS "mdw: варианты CPU-бэкенда: ${MDW_CPU_VARIANTS}")
add_dependencies(markitdown_whisper ${MDW_CPU_VARIANTS})
