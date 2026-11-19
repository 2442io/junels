#!/usr/bin/env bash
# Lädt die getesteten Versionen von llama.cpp und whisper.cpp nach third_party/
# (einmalig, braucht Internet).
set -euo pipefail
LLAMA_TAG="${LLAMA_TAG:-b12522}"
WHISPER_COMMIT="${WHISPER_COMMIT:-6680804f99c3982b7d59f27ae315ce880570017e}"
SD_COMMIT="${SD_COMMIT:-532d2c15c430a785a712b2d94281f04e733008a4}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/third_party"

LLAMA="$ROOT/third_party/llama.cpp"
if [ ! -f "$LLAMA/CMakeLists.txt" ]; then
  echo "Lade llama.cpp $LLAMA_TAG …"
  git clone --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp.git "$LLAMA"
  rm -rf "$LLAMA/.git"
fi

WHISPER="$ROOT/third_party/whisper.cpp"
if [ ! -f "$WHISPER/src/whisper.cpp" ]; then
  echo "Lade whisper.cpp ${WHISPER_COMMIT:0:8} …"
  mkdir -p "$WHISPER"
  (cd "$WHISPER" && git init -q && git remote add origin https://github.com/ggml-org/whisper.cpp.git \
    && git fetch -q --depth 1 origin "$WHISPER_COMMIT" && git checkout -q FETCH_HEAD)
  rm -rf "$WHISPER/.git"
fi

SD="$ROOT/third_party/stable-diffusion.cpp"
if [ ! -f "$SD/CMakeLists.txt" ]; then
  echo "Lade stable-diffusion.cpp ${SD_COMMIT:0:8} …"
  mkdir -p "$SD"
  (cd "$SD" && git init -q && git remote add origin https://github.com/leejet/stable-diffusion.cpp.git \
    && git fetch -q --depth 1 origin "$SD_COMMIT" && git checkout -q FETCH_HEAD)
  rm -rf "$SD/.git"
  # Wörterbücher großer Text-Encoder (Flux/Qwen-Image …) leeren: die App nutzt nur
  # SD-Modelle mit CLIP. Spart ~30 MB in der App.
  python3 "$ROOT/scripts/slim_sd_vocab.py" "$SD/src/tokenizers/vocab"
fi
echo "Quellen bereit: $ROOT/third_party"
