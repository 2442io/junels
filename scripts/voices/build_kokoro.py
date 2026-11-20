#!/usr/bin/env python3
"""Baut das Stimmenpaket „Kokoro Deutsch – Martin“ für sherpa-onnx.

Quelle: prinzsimo/Kokoro-82M-German-Martin (Apache-2.0, Fine-Tune von Kokoro-82M).
Ergebnis: kokoro-de-martin/ mit model.onnx (+ Metadaten), voices.bin, tokens.txt,
espeak-ng-data/ und LICENSE – so wie sherpa-onnx Kokoro-Modelle erwartet.
"""
import json
import os
import shutil
import sys
import tarfile
import urllib.request
from pathlib import Path

import numpy as np
import onnx
from huggingface_hub import hf_hub_download

# Mögliche Quellen (die erste, die eine ONNX-Datei und eine Stimme hat, wird genommen)
VOICE = (sys.argv[2] if len(sys.argv) > 2 else "martin").lower()
CANDIDATES = [
    f"huggingFresse/Kokoro-82M-ONNX-German-{VOICE.capitalize()}",
    f"prinzsimo/Kokoro-82M-German-{VOICE.capitalize()}",
]
REPO = ""
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "kokoro-de-martin")
ESPEAK = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/espeak-ng-data.tar.bz2"


def find_source():
    from huggingface_hub import HfApi
    api = HfApi()
    # weitere Kandidaten über die Hugging-Face-Suche
    try:
        for m in api.list_models(search=f"kokoro german {VOICE}", limit=30):
            if m.id not in CANDIDATES:
                CANDIDATES.append(m.id)
        for m in api.list_models(search=f"kokoro {VOICE} onnx", limit=30):
            if m.id not in CANDIDATES:
                CANDIDATES.append(m.id)
    except Exception as e:
        print("Suche fehlgeschlagen:", e)
    print("Kandidaten:", CANDIDATES)
    for repo in CANDIDATES:
        try:
            files = api.list_repo_files(repo)
        except Exception as e:
            print(f"{repo}: nicht verfügbar ({type(e).__name__})")
            continue
        print(f"{repo}: {files}")
        onnx_files = [f for f in files if f.endswith(".onnx")]
        # unquantisiert bevorzugen
        onnx_files.sort(key=lambda f: (any(q in f.lower() for q in ("int8", "q8", "quant", "fp16", "uint8")), len(f)))
        if "coreml" in repo.lower() or VOICE not in (repo + " ".join(files)).lower():
            continue
        voice_files = [f for f in files if f.endswith((".npz", ".npy")) or (f.endswith(".bin") and "voice" in f.lower())
                       or (f.endswith(".pt") and "voice" in f.lower())]
        if onnx_files and voice_files:
            return repo, onnx_files[0], voice_files[0], files
    raise SystemExit("Keine passende Quelle gefunden")


def load_styles(path):
    if path.endswith(".npz"):
        npz = np.load(path)
        return list(npz.files), [np.asarray(npz[k], dtype=np.float32) for k in npz.files]
    if path.endswith(".npy"):
        return [VOICE], [np.load(path).astype(np.float32)]
    if path.endswith(".pt"):
        import torch
        return [VOICE], [torch.load(path, map_location="cpu", weights_only=True).numpy().astype(np.float32)]
    raw = np.fromfile(path, dtype=np.float32)
    return [VOICE], [raw.reshape(-1, 1, 256)]


def main():
    global REPO
    OUT.mkdir(parents=True, exist_ok=True)
    REPO, onnx_name, voice_name, files = find_source()
    print("Quelle:", REPO, onnx_name, voice_name)
    model_path = hf_hub_download(REPO, onnx_name)
    voices_path = hf_hub_download(REPO, voice_name)
    vocab = None
    for name in [f for f in files if f.endswith(("vocab_index.json", "config.json", "tokens.txt"))]:
        try:
            pth = hf_hub_download(REPO, name)
            if name.endswith("tokens.txt"):
                vocab = {}
                for line in open(pth, encoding="utf-8"):
                    if line.strip():
                        sym, _, idx = line.rstrip("\n").rpartition(" ")
                        vocab[sym] = int(idx)
            else:
                j = json.load(open(pth, encoding="utf-8"))
                vocab = j.get("vocab", j) if isinstance(j, dict) else j
            print("Vokabular aus", name)
            break
        except Exception as e:
            print(name, "unbrauchbar:", e)
    if not vocab or (isinstance(vocab, dict) and len(vocab) < 50):
        print("Nutze Vokabular des Original-Kokoro")
        vocab = json.load(open(hf_hub_download("hexgrad/Kokoro-82M", "config.json"), encoding="utf-8"))["vocab"]
    if isinstance(vocab, dict) and "vocab" in vocab:
        vocab = vocab["vocab"]
    if isinstance(vocab, list):
        vocab = {s: i for i, s in enumerate(vocab) if s}
    # Werte könnten Strings sein
    vocab = {k: int(v) for k, v in vocab.items()}
    print("Vokabular:", len(vocab), "Zeichen, Leerzeichen:", " " in vocab)

    # tokens.txt: „Symbol ID“ pro Zeile
    with open(OUT / "tokens.txt", "w", encoding="utf-8") as f:
        for k, i in sorted(vocab.items(), key=lambda x: x[1]):
            f.write(f"{k} {i}\n")

    # voices.bin: rohe float32-Stile, ein Sprecher
    names, raw = load_styles(voices_path)
    print("Stimmen:", {n: a.shape for n, a in zip(names, raw)})
    styles = []
    for a in raw:
        if a.ndim == 2:
            a = a.reshape(a.shape[0], 1, a.shape[1])
        styles.append(a)
    shape = styles[0].shape
    assert all(s.shape == shape for s in styles), "unterschiedliche Stil-Formen"
    assert shape[1] == 1, f"unerwartete Stil-Form {shape}"
    with open(OUT / "voices.bin", "wb") as f:
        for s in styles:
            f.write(s.tobytes())

    # Modell mit sherpa-onnx-Metadaten
    model = onnx.load(model_path)
    print("Eingänge:", [(i.name, i.type.tensor_type.elem_type) for i in model.graph.input])
    meta = {
        "model_type": "kokoro",
        "language": "German",
        "has_espeak": 1,
        "sample_rate": 24000,
        "version": 2,
        "voice": "de",
        "style_dim": ",".join(map(str, shape)),
        "n_speakers": len(names),
        "speaker_names": ",".join(names),
        "model_url": "https://huggingface.co/" + REPO,
        "comment": f"Kokoro-82M German fine-tune '{VOICE}' (Apache-2.0), packaged for sherpa-onnx by Junels",
    }
    while len(model.metadata_props):
        model.metadata_props.pop()
    for k, v in meta.items():
        p = model.metadata_props.add()
        p.key = k
        p.value = str(v)
    onnx.save(model, str(OUT / "model.onnx"))

    # espeak-ng-Daten (Aussprache)
    if not (OUT / "espeak-ng-data").exists():
        tmp = Path("espeak-ng-data.tar.bz2")
        urllib.request.urlretrieve(ESPEAK, tmp)
        with tarfile.open(tmp) as t:
            t.extractall(OUT)
        tmp.unlink()

    (OUT / "LICENSE").write_text(
        f"Kokoro-82M German '{VOICE}' – Apache License 2.0\n"
        "Quelle: https://huggingface.co/" + REPO + "\n"
        "Basis: https://huggingface.co/hexgrad/Kokoro-82M (Apache-2.0)\n"
        "espeak-ng-data: GPL-3.0 (https://github.com/espeak-ng/espeak-ng)\n",
        encoding="utf-8",
    )
    print("fertig:", sorted(os.listdir(OUT)))


if __name__ == "__main__":
    main()
