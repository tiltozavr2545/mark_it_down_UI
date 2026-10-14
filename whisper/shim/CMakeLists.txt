# Собирает markitdown_whisper — прослойку mdw (mdw.h) — вместе с whisper.cpp,
# ggml и libopus. Запускается из whisper/build.sh, пути к исходникам
# передаются им же (-DMDW_*_DIR).
#
# На выходе в ${CMAKE_BINARY_DIR}/bin (туда же пишет сам whisper.cpp) — всё,
# что едет в приложение:
#   markitdown_whisper  — наша прослойка (miniaudio, libopus вшиты статически)
#   whisper, ggml, ggml-base — shared: варианты CPU-бэкенда ниже линкуются
#                         с ggml-base и без shared-сборки невозможны
#   ggml-cpu-<вариант>  — CPU-бэкенд под разные наборы инструкций (SSE4.2,
#                         AVX2, AVX-512… / armv8.0 … armv9.2); при запуске
#                         ggml берёт лучший, что тянет процессор
#
# Почему варианты, а не одна сборка: под AVX2 приложение падает целиком
# («illegal instruction») на процессоре без AVX2 — а это ещё и Pentium/
# Celeron 2020-х; под голый SSE — медленно в разы на всех остальных.
cmake_minimum_required(VERSION 3.16)
project(markitdown_whisper C CXX)
# whisper.cpp объявляет cmake_minimum_required старше 3.13, и без этого его
# option(BUILD_SHARED_LIBS …) затирает значение, выставленное здесь.
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
# Каталог переносится целиком: библиотеки ищут соседей рядом с собой.
if(APPLE)
  set(CMAKE_INSTALL_NAME_DIR "@rpath")
  set(CMAKE_BUILD_RPATH "@loader_path")
  set(CMAKE_BUILD_WITH_INSTALL_NAME_DIR ON)
elseif(UNIX)
  set(CMAKE_BUILD_RPATH "\$ORIGIN")
endif()

# --- libopus: статически внутрь markitdown_whisper. Добавляется ДО
# whisper.cpp: глобальный BUILD_SHARED_LIBS=ON сделал бы её shared.
set(BUILD_SHARED_LIBS OFF)
set(OPUS_BUILD_SHARED_LIBRARY OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
# Нейросетевые надстройки Opus 1.5+ (восстановление потерь, улучшение
# речи) — для декодирования файла без потерь пакетов не нужны, а весят
# мегабайты.
set(OPUS_DRED OFF CACHE BOOL "" FORCE)
set(OPUS_OSCE OFF CACHE BOOL "" FORCE)
add_subdirectory("${MDW_OPUS_DIR}" opus EXCLUDE_FROM_ALL)

# --- whisper.cpp + ggml ---
set(BUILD_SHARED_LIBS ON)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(WHISPER_CURL OFF CACHE BOOL "" FORCE)   # скачивание модели по URL — нет
set(WHISPER_SDL2 OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)    # не под процессор сборочной машины
set(GGML_BACKEND_DL ON CACHE BOOL "" FORCE)
set(GGML_CPU_ALL_VARIANTS ON CACHE BOOL "" FORCE)
# Свой пул потоков ggml вместо OpenMP: иначе на Windows нужен vcomp140.dll,
# которого у пользователя может не быть, на Android — libomp.so.
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_RPC OFF CACHE BOOL "" FORCE)       # бэкенд по сети — нет
set(GGML_METAL OFF CACHE BOOL "" FORCE)     # только CPU, одинаково везде
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
  # mfplat/mfreadwrite — не здесь: грузятся динамически
  # (mdw_platform_windows.cpp), mfuuid — только GUID-ы, статическая.
  target_link_libraries(markitdown_whisper PRIVATE mfuuid ole32)
  # miniaudio и stb_vorbis зовут fopen/strcpy — предупреждения MSVC о
  # «небезопасных» функциях к нам не относятся.
  target_compile_definitions(markitdown_whisper PRIVATE _CRT_SECURE_NO_WARNINGS)
else()
  target_link_libraries(markitdown_whisper PRIVATE m)
endif()

# Варианты CPU-бэкенда — MODULE-библиотеки, от которых whisper не зависит:
# без явной зависимости `--target markitdown_whisper` их бы не собрал.
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
