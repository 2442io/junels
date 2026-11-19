# Baut libagent_engine (Shared Library) mit statisch eingebundenem llama.cpp.
# Wird von Android (Gradle externalNativeBuild), vom Apple-Build-Skript
# und für Tests unter Linux/macOS verwendet.
cmake_minimum_required(VERSION 3.18)
project(agent_engine VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Pfad zu llama.cpp (scripts/fetch_llama.sh legt es unter third_party/ ab)
if(NOT DEFINED LLAMA_CPP_DIR)
  set(LLAMA_CPP_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../third_party/llama.cpp")
endif()
get_filename_component(LLAMA_CPP_DIR "${LLAMA_CPP_DIR}" ABSOLUTE)
if(NOT EXISTS "${LLAMA_CPP_DIR}/CMakeLists.txt")
  message(FATAL_ERROR "llama.cpp nicht gefunden unter ${LLAMA_CPP_DIR}. Bitte scripts/fetch_llama.sh ausführen.")
endif()

# llama.cpp: nur die Bibliothek, statisch, ohne Netzwerk-Features
set(BUILD_SHARED_LIBS     OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS     OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS     OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES  OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP       OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL         OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL            OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_IS_DEV    OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE           OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP           OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE        OFF CACHE BOOL "" FORCE)
# Bildverständnis: libmtmd (ohne Video/ffmpeg)
set(LLAMA_BUILD_MTMD      ON  CACHE BOOL "" FORCE)
set(MTMD_VIDEO            OFF CACHE BOOL "" FORCE)

if(ANDROID)
  # Gradle baut Debug-Varianten sonst ohne Optimierung
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
  # ARMv8.2 mit dotprod: praktisch alle Android-Geräte ab ca. 2019
  if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod" CACHE STRING "" FORCE)
  endif()
  set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
endif()

if(APPLE)
  set(GGML_METAL                ON  CACHE BOOL "" FORCE)
  set(GGML_METAL_EMBED_LIBRARY  ON  CACHE BOOL "" FORCE)
  set(GGML_BLAS                 OFF CACHE BOOL "" FORCE)
endif()

# Stable Diffusion braucht längere Tensor-Namen; gilt für alle ggml-Nutzer gleich,
# damit die ggml_tensor-Struktur überall identisch ist.
add_compile_definitions(GGML_MAX_NAME=160)

add_subdirectory("${LLAMA_CPP_DIR}" llama_build EXCLUDE_FROM_ALL)

# whisper.cpp: nur die Quelldateien, gebaut gegen das ggml von llama.cpp
# (beide Projekte teilen ggml; so gibt es keine doppelten Symbole)
if(NOT DEFINED WHISPER_CPP_DIR)
  set(WHISPER_CPP_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../third_party/whisper.cpp")
endif()
get_filename_component(WHISPER_CPP_DIR "${WHISPER_CPP_DIR}" ABSOLUTE)
if(NOT EXISTS "${WHISPER_CPP_DIR}/src/whisper.cpp")
  message(FATAL_ERROR "whisper.cpp nicht gefunden unter ${WHISPER_CPP_DIR}. Bitte scripts/fetch_llama.sh ausführen.")
endif()
add_library(whisper_lib STATIC
  "${WHISPER_CPP_DIR}/src/whisper.cpp"
  "${WHISPER_CPP_DIR}/src/aneforge/whisper-aneforge.cpp")
target_include_directories(whisper_lib PUBLIC "${WHISPER_CPP_DIR}/include" "${WHISPER_CPP_DIR}/src")
target_link_libraries(whisper_lib PUBLIC ggml)
set_target_properties(whisper_lib PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_compile_definitions(whisper_lib PRIVATE WHISPER_VERSION="1.9.5-ae")

# stable-diffusion.cpp: Bildgenerierung, gegen das ggml von llama.cpp gebaut
if(NOT DEFINED SD_CPP_DIR)
  set(SD_CPP_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../third_party/stable-diffusion.cpp")
endif()
get_filename_component(SD_CPP_DIR "${SD_CPP_DIR}" ABSOLUTE)
option(AE_WITH_SD "Bildgenerierung (stable-diffusion.cpp)" ON)
set(AE_SD_SOURCES "")
if(AE_WITH_SD AND EXISTS "${SD_CPP_DIR}/CMakeLists.txt")
  set(SD_USE_SYSTEM_GGML   ON  CACHE BOOL "" FORCE)  # vorhandenes ggml-Target verwenden
  set(SD_USE_UPSTREAM_GGML ON  CACHE BOOL "" FORCE)
  set(SD_GGML_SOURCE_DIR "${LLAMA_CPP_DIR}/ggml" CACHE PATH "" FORCE)
  set(SD_BUILD_EXAMPLES    OFF CACHE BOOL "" FORCE)
  set(SD_WEBP              OFF CACHE BOOL "" FORCE)
  set(SD_WEBM              OFF CACHE BOOL "" FORCE)
  set(SD_BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
  add_subdirectory("${SD_CPP_DIR}" sd_build EXCLUDE_FROM_ALL)
  set(AE_SD_SOURCES image_engine.cpp)
  set(AE_HAVE_SD ON)
endif()

add_library(agent_engine SHARED agent_engine.cpp stt_engine.cpp ${AE_SD_SOURCES})
target_link_libraries(agent_engine PRIVATE llama mtmd whisper_lib)
if(AE_HAVE_SD)
  target_link_libraries(agent_engine PRIVATE stable-diffusion)
  target_compile_definitions(agent_engine PRIVATE AE_HAVE_SD=1)
endif()
set_target_properties(agent_engine PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)

if(ANDROID)
  # 16-KB-Seiten (Android 15+)
  target_link_options(agent_engine PRIVATE "-Wl,-z,max-page-size=16384")
  target_link_libraries(agent_engine PRIVATE log)
endif()

if(APPLE AND AE_BUILD_FRAMEWORK)
  # Dynamisches Framework für die xcframework (iOS/iPadOS und macOS)
  if(NOT DEFINED AE_MIN_OS)
    set(AE_MIN_OS "${CMAKE_OSX_DEPLOYMENT_TARGET}")
  endif()
  configure_file("${CMAKE_CURRENT_LIST_DIR}/Info.plist.in" "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)
  set_target_properties(agent_engine PROPERTIES
    FRAMEWORK TRUE
    FRAMEWORK_VERSION A
    OUTPUT_NAME AgentEngine
    MACOSX_FRAMEWORK_IDENTIFIER io.t24.agentengine
    MACOSX_FRAMEWORK_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    PUBLIC_HEADER agent_engine.h
    INSTALL_NAME_DIR "@rpath"
    BUILD_WITH_INSTALL_NAME_DIR ON)
  target_link_libraries(agent_engine PRIVATE "-framework Foundation" "-framework Metal" "-framework MetalKit" "-framework Accelerate")
endif()
