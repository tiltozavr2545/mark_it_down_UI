# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(markitdown_ui LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "markitdown_ui")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# PDFium (Stage 3/5): pdfium.dll — next to the .exe, where LoadLibrary looks
# for it first (see loadPdfiumLibrary in core/). Fetched by pdfium/fetch.sh,
# not committed to the repository. Without it the build fails here, instead
# of shipping an app where no PDF would silently open.
set(PDFIUM_DLL "${CMAKE_CURRENT_SOURCE_DIR}/../../pdfium/native/host/pdfium.dll")
if(NOT EXISTS "${PDFIUM_DLL}")
  message(FATAL_ERROR "Нет ${PDFIUM_DLL} — сначала ./pdfium/fetch.sh (Git Bash)")
endif()
install(FILES "${PDFIUM_DLL}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# Tesseract (Stage 6, OCR): leptonica-*.dll and tesseract*.dll — next to the
# .exe, where loadTesseractLibraries in core/ looks for them. Built by
# tesseract/build.sh (cached in CI), not committed to the repository.
# Mandatory, like PDFium: without them OCR would silently disappear from the
# build. Models (*.traineddata) travel as Flutter assets, not from here.
file(GLOB TESSERACT_DLLS
  "${CMAKE_CURRENT_SOURCE_DIR}/../../tesseract/native/host/leptonica*.dll"
  "${CMAKE_CURRENT_SOURCE_DIR}/../../tesseract/native/host/tesseract*.dll")
list(LENGTH TESSERACT_DLLS TESSERACT_DLL_COUNT)
if(NOT TESSERACT_DLL_COUNT EQUAL 2)
  message(FATAL_ERROR "Нет DLL Tesseract в tesseract/native/host — сначала ./tesseract/build.sh (Git Bash)")
endif()
install(FILES ${TESSERACT_DLLS} DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# Speech recognition (0.8): markitdown_whisper.dll (our shim), whisper,
# ggml, ggml-base, and the CPU-backend variants ggml-cpu-*.dll — next to the
# .exe, where loadWhisperLibrary in core/ looks for them and from where ggml
# picks the variant for the CPU. Built by whisper/build.sh (cached in CI),
# not committed to the repository. Mandatory, like Tesseract: without them
# recognition would silently disappear from the build. Models travel as
# Flutter assets (whisper/fetch.sh). Each mandatory DLL is checked by name
# rather than by total count: there are about a dozen ggml-cpu-*.dll
# variants alone (GGML_CPU_ALL_VARIANTS), and the count would pass even
# without the shim.
set(WHISPER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../whisper/native/host")
set(WHISPER_DLLS)
foreach(WHISPER_DLL markitdown_whisper whisper ggml ggml-base)
  if(NOT EXISTS "${WHISPER_DIR}/${WHISPER_DLL}.dll")
    message(FATAL_ERROR "Нет ${WHISPER_DLL}.dll в whisper/native/host — сначала ./whisper/build.sh (Git Bash)")
  endif()
  list(APPEND WHISPER_DLLS "${WHISPER_DIR}/${WHISPER_DLL}.dll")
endforeach()
file(GLOB WHISPER_CPU_DLLS "${WHISPER_DIR}/ggml-cpu-*.dll")
if(NOT WHISPER_CPU_DLLS)
  message(FATAL_ERROR "Нет ни одного ggml-cpu-*.dll в whisper/native/host — сначала ./whisper/build.sh (Git Bash)")
endif()
install(FILES ${WHISPER_DLLS} ${WHISPER_CPU_DLLS}
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)

# Python sidecar (Stage 5, item 4): sidecar/ next to the .exe, where
# SidecarConverter.discover() looks for it. Optional: without a built
# sidecar/dist/windows-x86_64 you get a Dart-only build — a normal state,
# not a broken one (xls/msg then honestly say "unsupported").
set(SIDECAR_DIST_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../sidecar/dist/windows-x86_64")
if(EXISTS "${SIDECAR_DIST_DIR}/manifest.json")
  install(DIRECTORY "${SIDECAR_DIST_DIR}/" DESTINATION "${CMAKE_INSTALL_PREFIX}/sidecar"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
