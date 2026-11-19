#!/usr/bin/env python3
"""Ersetzt die großen Tokenizer-Daten von stable-diffusion.cpp durch leere Platzhalter.
CLIP (für SD 1.x/2.x/XL) bleibt erhalten."""
import pathlib, re, sys

d = pathlib.Path(sys.argv[1])
for f in d.glob("*.hpp"):
    if f.name.startswith("clip"):
        continue
    text = f.read_text(errors="ignore")[:400]
    names = re.findall(r"static const unsigned char (\w+)\[\]", text)
    if not names:
        continue
    empty = "0x7b,0x7d," if ("json" in names[0] or "vocab" in names[0]) else "0x0a,"
    f.write_text("".join(f"static const unsigned char {n}[] = {{{empty}}};\n" for n in names))
    print("geleert:", f.name)
