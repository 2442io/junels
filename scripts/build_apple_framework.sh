#!/usr/bin/env bash
# Baut AgentEngine.xcframework (llama.cpp + Metal) für iPad, iOS-Simulator und macOS
# und legt sie in packages/agent_engine/{ios,macos}/Frameworks ab.
# Voraussetzungen: macOS mit Xcode, CMake (brew install cmake).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/packages/agent_engine/src"
OUT="$ROOT/build/apple"
IOS_MIN="16.0"
MAC_MIN="12.0"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
# Welche Varianten gebaut werden (CI baut nur macos, spart Build-Minuten)
TARGETS="${AE_APPLE_TARGETS:-ios ios-sim macos}"

[ "$(uname)" = "Darwin" ] || { echo "Nur auf macOS ausführbar."; exit 1; }
command -v cmake >/dev/null || { echo "CMake fehlt: brew install cmake"; exit 1; }
bash "$ROOT/scripts/fetch_llama.sh"

build() {
  local name="$1"; shift
  echo "==> Baue $name"
  cmake -S "$SRC" -B "$OUT/$name" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DAE_BUILD_FRAMEWORK=ON \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    "$@" > "$OUT/$name.cmake.log"
  cmake --build "$OUT/$name" --target agent_engine -j "$JOBS" > "$OUT/$name.build.log" \
    || { echo "Fehler, siehe $OUT/$name.build.log"; tail -30 "$OUT/$name.build.log"; exit 1; }
}

rm -rf "$OUT"
mkdir -p "$OUT"

ARGS=()
for t in $TARGETS; do
  case "$t" in
    ios)
      build ios -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" -DAE_MIN_OS="$IOS_MIN" ;;
    ios-sim)
      build ios-sim -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator \
        -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" -DAE_MIN_OS="$IOS_MIN" ;;
    macos)
      build macos -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MAC_MIN" -DAE_MIN_OS="$MAC_MIN" ;;
  esac
  ARGS+=(-framework "$OUT/$t/AgentEngine.framework")
done

echo "==> Erzeuge AgentEngine.xcframework"
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT/AgentEngine.xcframework" > /dev/null

for plat in ios macos; do
  dest="$ROOT/packages/agent_engine/$plat/Frameworks"
  rm -rf "$dest/AgentEngine.xcframework"
  mkdir -p "$dest"
  cp -R "$OUT/AgentEngine.xcframework" "$dest/"
done

echo "Fertig. Exportierte Symbole:"
nm -gU "$(find "$OUT" -path "*AgentEngine.framework*" -name AgentEngine -type f | head -1)" | grep " _ae_" | head -20
