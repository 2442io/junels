#!/usr/bin/env bash
# Baut die Engine für den Rechner (macOS/Linux) und führt die Kern-Tests aus.
#   ./test_engine.sh /pfad/zu/modell.gguf
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="${1:-}"
bash "$ROOT/scripts/fetch_llama.sh"
B="$ROOT/build/host"
cmake -S "$ROOT/packages/agent_engine/src" -B "$B" -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build "$B" --target agent_engine -j 8 > /dev/null
LIB="$(ls "$B"/libagent_engine.* | head -1)"
cd "$ROOT/packages/agent_engine"
dart pub get --offline > /dev/null 2>&1 || dart pub get > /dev/null
AE_LIB_PATH="$LIB" AE_TEST_MODEL="$MODEL" dart run test/engine_test.dart
