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

REPO = "prinzsimo/Kokoro-82M-German-Martin"
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "kokoro-de-martin")
ESPEAK = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/espeak-ng-data.tar.bz2"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    model_path = hf_hub_download(REPO, "kokoro-martin.onnx")
    voices_path = hf_hub_download(REPO, "voices-martin.npz")
    try:
        vocab_path = hf_hub_download(REPO, "vocab_index.json")
        vocab = json.load(open(vocab_path, encoding="utf-8"))
    except Exception as e:  # Fallback: Vokabular des Original-Kokoro
        print("vocab_index.json nicht verfügbar:", e)
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
    npz = np.load(voices_path)
    print("Stimmen in npz:", {k: npz[k].shape for k in npz.files})
    names = list(npz.files)
    styles = []
    for n in names:
        a = np.asarray(npz[n], dtype=np.float32)
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
        "model_url": f"https://huggingface.co/{REPO}",
        "comment": "Kokoro-82M German fine-tune 'Martin' (Apache-2.0), packaged for sherpa-onnx by Junels",
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
        "Kokoro-82M German 'Martin' – Apache License 2.0\n"
        f"Quelle: https://huggingface.co/{REPO}\n"
        "Basis: https://huggingface.co/hexgrad/Kokoro-82M (Apache-2.0)\n"
        "espeak-ng-data: GPL-3.0 (https://github.com/espeak-ng/espeak-ng)\n",
        encoding="utf-8",
    )
    print("fertig:", sorted(os.listdir(OUT)))


if __name__ == "__main__":
    main()
