#!/usr/bin/env python3
"""Vergleicht Spracherkenner für Deutsch: Tempo (Echtzeitfaktor) und Genauigkeit.
Testsätze spricht Kokoro Martin (aus dem Release „stimmen“)."""
import difflib, glob, os, re, sys, tarfile, time, urllib.request
import numpy as np
import sherpa_onnx

SENT = [
    "Wie wird das Wetter morgen in Wien?",
    "Erinnere mich bitte um acht Uhr an den Zahnarzttermin.",
    "Junels, such mir auf Amazon eine spülmaschinenfeste Brotdose.",
    "Was gibt es Neues bei Anthropic und OpenAI?",
    "Schreib meiner Schwester eine WhatsApp, dass ich später komme.",
]
REL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"

def get(url, name):
    if not os.path.exists(name):
        urllib.request.urlretrieve(url, name)
    d = name.replace(".tar.bz2", "")
    if not os.path.isdir(d):
        with tarfile.open(name) as t: t.extractall(".")
    return d

kd = get("https://github.com/2442io/junels/releases/download/stimmen/kokoro-de-martin.tar.bz2", "kokoro-de-martin.tar.bz2")
tts = sherpa_onnx.OfflineTts(sherpa_onnx.OfflineTtsConfig(model=sherpa_onnx.OfflineTtsModelConfig(
    kokoro=sherpa_onnx.OfflineTtsKokoroModelConfig(model=f"{kd}/model.onnx", voices=f"{kd}/voices.bin",
        tokens=f"{kd}/tokens.txt", data_dir=f"{kd}/espeak-ng-data", lang="de"), num_threads=2)))
clips = []
for s in SENT:
    a = tts.generate(s, sid=0, speed=1.0)
    x = np.array(a.samples, dtype=np.float32)
    # auf 16 kHz
    n = int(len(x) * 16000 / a.sample_rate)
    x16 = np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x).astype(np.float32)
    clips.append(x16)

norm = lambda s: re.sub(r"[^a-zäöüß ]", "", s.lower()).split()
def score(ref, hyp):
    return difflib.SequenceMatcher(None, norm(ref), norm(hyp)).ratio()

def bench(name, rec):
    tot_a = tot_t = 0; sc = []
    for s, x in zip(SENT, clips):
        st = rec.create_stream(); st.accept_waveform(16000, x)
        t0 = time.time(); rec.decode_stream(st); dt = time.time() - t0
        tot_a += len(x) / 16000; tot_t += dt; sc.append(score(s, st.result.text))
        print(f"  [{name}] {st.result.text}")
    print(f"== {name}: Echtzeitfaktor {tot_t / tot_a:.2f}, Genauigkeit {np.mean(sc):.2f}")

cands = sys.argv[1:]
for c in cands:
    try:
        d = get(REL + c + ".tar.bz2", c + ".tar.bz2")
        f = lambda p: (sorted(glob.glob(f"{d}/{p}")) or [""])[0]
        if "canary" in c:
            rec = sherpa_onnx.OfflineRecognizer.from_nemo_canary(encoder=f("*encoder*.onnx"), decoder=f("*decoder*.onnx"),
                tokens=f("tokens.txt"), src_lang="de", tgt_lang="de", num_threads=2)
        elif "parakeet" in c or "transducer" in c:
            rec = sherpa_onnx.OfflineRecognizer.from_transducer(encoder=f("encoder*.onnx"), decoder=f("decoder*.onnx"),
                joiner=f("joiner*.onnx"), tokens=f("tokens.txt"), model_type="nemo_transducer", num_threads=2)
        elif "whisper" in c:
            rec = sherpa_onnx.OfflineRecognizer.from_whisper(encoder=f("*encoder*.onnx"), decoder=f("*decoder*.onnx"),
                tokens=f("*tokens.txt"), language="de", num_threads=2)
        else:
            continue
        bench(c, rec)
    except Exception as e:
        print(f"== {c}: Fehler {e}")
