#!/bin/bash
# whisper.cpp + llama.cpp를 ggml 공유(중복 심볼 회피)로 결합해
# IpCoding/Vendor/IpCodingEngine.xcframework를 생성한다 (태스크 2.2).
#
# 배경: 두 프로젝트를 각자 ggml 정적 포함 xcframework로 링크하면 중복 심볼로 실패한다.
# whisper.cpp CMakeLists의 `if (NOT TARGET ggml)` 가드를 이용해, 상위 CMake에서 llama.cpp를
# 먼저 로드(ggml 타겟 생성)한 뒤 whisper.cpp를 로드하면 ggml을 공유한다.
#
# 산출물: Vendor/IpCodingEngine.xcframework (모듈명 IpCodingEngine, import 한 줄로 양쪽 C API).
# Vendor/는 .gitignore이므로 개발/CI에서 이 스크립트로 재생성한다.
set -euo pipefail

# 검증된 커밋 (2.1/2.2 스파이크 시점). 갱신 시 ggml 호환·qwen35 지원 재확인.
LLAMA_COMMIT="082b326fc76f6e9bbb835b3920a3022bfdb6691c"   # qwen35 arch 지원 (mainline)
WHISPER_COMMIT="6fc7c33b4c3a2cec83e4b65abd5e96a890480375"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ">>> clone"
git -C "$WORK" clone https://github.com/ggml-org/llama.cpp.git
git -C "$WORK/llama.cpp" checkout "$LLAMA_COMMIT"
git -C "$WORK" clone https://github.com/ggml-org/whisper.cpp.git
git -C "$WORK/whisper.cpp" checkout "$WHISPER_COMMIT"

echo ">>> superproject CMakeLists (shared ggml)"
cat > "$WORK/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.14)
project(ipcoding-combined C CXX)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "" FORCE)
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "" FORCE)
set(GGML_METAL ON CACHE BOOL "" FORCE)
set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "" FORCE)
set(GGML_BLAS_DEFAULT ON CACHE BOOL "" FORCE)
set(GGML_METAL_USE_BF16 ON CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_MTMD OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(WHISPER_COREML OFF CACHE BOOL "" FORCE)
set(WHISPER_SDL2 OFF CACHE BOOL "" FORCE)
set(WHISPER_CURL OFF CACHE BOOL "" FORCE)
# llama.cpp first defines the shared ggml target; whisper.cpp then reuses it
# (its `if (NOT TARGET ggml)` guard skips vendoring its own copy).
add_subdirectory(${WORK}/llama.cpp llama-build)
add_subdirectory(${WORK}/whisper.cpp whisper-build)
EOF

echo ">>> build (static, Metal embedded)"
cmake -S "$WORK" -B "$WORK/build" -G Xcode >/dev/null
cmake --build "$WORK/build" --config Release --target whisper llama ggml -- -quiet

echo ">>> combine static libs into one framework + xcframework"
# 정적 라이브러리(libwhisper, libllama, libggml*)를 하나의 동적 framework로 결합.
FW="$WORK/IpCodingEngine.framework"
mkdir -p "$FW/Versions/A/Headers" "$FW/Versions/A/Modules"
LIBS=$(find "$WORK/build" -name "*.a" | tr '\n' ' ')
# shellcheck disable=SC2086
libtool -static -o "$WORK/combined.a" $LIBS
clang++ -dynamiclib -arch arm64 -mmacosx-version-min=14.0 \
  -framework Foundation -framework Metal -framework Accelerate \
  -Wl,-force_load,"$WORK/combined.a" \
  -install_name "@rpath/IpCodingEngine.framework/Versions/A/IpCodingEngine" \
  -o "$FW/Versions/A/IpCodingEngine"

# 헤더 수집: llama.h가 ggml-opt.h까지 전이 include하므로 ggml/include 전부 복사.
cp "$WORK"/whisper.cpp/include/whisper.h "$FW/Versions/A/Headers/"
cp "$WORK"/llama.cpp/include/llama.h "$FW/Versions/A/Headers/"
cp "$WORK"/llama.cpp/ggml/include/*.h "$FW/Versions/A/Headers/"

# 모듈맵: C API 헤더만 노출. llama-cpp.h(C++ 래퍼, <memory> include)는 제외해야 C 모듈이 빌드된다.
cat > "$FW/Versions/A/Modules/module.modulemap" <<'MM'
framework module IpCodingEngine {
    header "whisper.h"
    header "llama.h"
    header "ggml.h"
    header "ggml-opt.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-cpu.h"
    header "gguf.h"
    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"
    export *
}
MM

(cd "$FW/Versions" && ln -sf A Current)
(cd "$FW" && ln -sf Versions/Current/Headers Headers && ln -sf Versions/Current/Modules Modules && ln -sf Versions/Current/IpCodingEngine IpCodingEngine)

OUT="$REPO_ROOT/IpCoding/Vendor/IpCodingEngine.xcframework"
rm -rf "$OUT"
xcodebuild -create-xcframework -framework "$FW" -output "$OUT"

echo ">>> done: $OUT"
nm "$OUT"/macos-arm64/IpCodingEngine.framework/IpCodingEngine 2>/dev/null | grep -cE "T _(whisper_full|llama_decode|ggml_init)$" | xargs echo "핵심 심볼 수(3 기대):"
