#!/usr/bin/env python3
"""Prüft ein Kokoro-Stimmenpaket: erzeugt deutschen Text und lässt ihn von Whisper zurückerkennen."""
import difflib
import re
import sys
import time
import wave

import numpy as np
import sherpa_onnx

d = sys.argv[1]
TEXT = "Guten Tag! Morgen wird es in Wien sonnig, mit bis zu achtzehn Grad. Möchtest du noch etwas wissen?"

cfg = sherpa_onnx.OfflineTtsConfig(
    model=sherpa_onnx.OfflineTtsModelConfig(
        kokoro=sherpa_onnx.OfflineTtsKokoroModelConfig(
            model=f"{d}/model.onnx", voices=f"{d}/voices.bin", tokens=f"{d}/tokens.txt",
            data_dir=f"{d}/espeak-ng-data", lang="de"),
        num_threads=2, debug=False),
)
tts = sherpa_onnx.OfflineTts(cfg)
t0 = time.time()
audio = tts.generate(TEXT, sid=0, speed=1.0)
dt = time.time() - t0
samples = np.array(audio.samples, dtype=np.float32)
dur = len(samples) / audio.sample_rate
print(f"Audio: {dur:.1f} s bei {audio.sample_rate} Hz, erzeugt in {dt:.1f} s (Echtzeitfaktor {dt / max(dur, 0.01):.2f})")
assert dur > 2, "kein/zu kurzes Audio"
with wave.open("probe.wav", "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(audio.sample_rate)
    w.writeframes((np.clip(samples, -1, 1) * 32767).astype(np.int16).tobytes())

from faster_whisper import WhisperModel
seg, _ = WhisperModel("small", compute_type="int8").transcribe("probe.wav", language="de")
heard = " ".join(s.text for s in seg).strip()
norm = lambda s: re.sub(r"[^a-zäöüß ]", "", s.lower().replace("18", "achtzehn"))
ratio = difflib.SequenceMatcher(None, norm(TEXT), norm(heard)).ratio()
print("Gesprochen:", TEXT)
print("Erkannt:   ", heard)
print(f"Übereinstimmung: {ratio:.2f}")
assert ratio > 0.75, "Aussprache zu schlecht – Stimme nicht veröffentlichen"
