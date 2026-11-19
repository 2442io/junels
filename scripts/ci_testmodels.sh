#!/usr/bin/env bash
# Lädt kleine echte Modelle für den Engine-Test im CI (Bildverständnis + Bildgenerierung).
set -euo pipefail
DIR="${1:-testmodels}"
mkdir -p "$DIR"
cd "$DIR"

pick() { # repo, grep-Muster → erster passender Dateiname im Repo
  curl -sfL "https://huggingface.co/api/models/$1/tree/main" \
    | python3 -c "import json,sys,re; fs=[f['path'] for f in json.load(sys.stdin) if f['type']=='file']; m=[f for f in fs if re.search(sys.argv[1], f)]; print(m[0] if m else '')" "$2"
}

VLM=ggml-org/SmolVLM-256M-Instruct-GGUF
if [ ! -s vlm-model.gguf ]; then
  f=$(pick $VLM '^(?!mmproj).*Q8_0\.gguf$'); [ -n "$f" ] || f=$(pick $VLM '^(?!mmproj).*\.gguf$')
  echo "Lade $VLM/$f"; curl -sfL -o vlm-model.gguf "https://huggingface.co/$VLM/resolve/main/$f"
fi
if [ ! -s vlm-mmproj.gguf ]; then
  f=$(pick $VLM '^mmproj.*\.gguf$')
  echo "Lade $VLM/$f"; curl -sfL -o vlm-mmproj.gguf "https://huggingface.co/$VLM/resolve/main/$f"
fi
if [ ! -s sd_turbo.gguf ]; then
  echo "Lade SD-Turbo"
  curl -sfL -o sd_turbo.gguf https://huggingface.co/Green-Sky/SD-Turbo-GGUF/resolve/main/sd_turbo-f16-q8_0.gguf
fi
ls -la
