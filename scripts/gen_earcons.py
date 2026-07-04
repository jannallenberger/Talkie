#!/usr/bin/env python3
"""K2 — synthesize Talkie's placeholder earcon family.

These are GENTLE, short, soft-enveloped sine chimes — deliberately subtle so they
sit under the interaction rather than announcing themselves. They are PLACEHOLDERS:
the intended final set is macaw-derived (recorded/processed from real macaw calls),
a human sound-design pass. This script is the checked-in provenance for the interim
assets; re-run it to regenerate them:  python3 scripts/gen_earcons.py

Requires only the Python stdlib + `afconvert` (bundled with macOS). Writes
Resources/Sounds/<name>.caf (CAF / 16-bit PCM), which `Feedback.swift` resolves
bundled-first, falling back to the same-purpose macOS system sound when absent.
"""
import math
import os
import struct
import subprocess
import wave

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Resources", "Sounds")

# name -> list of (freq_start_hz, freq_end_hz, duration_s, gain) segments.
# gain 0 = a silent gap. Kept quiet (<=0.34) and short so they never jar.
EARCONS = {
    "chirp-start":     [(680, 1040, 0.13, 0.32)],                                  # rising: "listening"
    "chirp-stop":      [(1040, 680, 0.13, 0.30)],                                  # falling: "done"
    "chirp-done":      [(900, 900, 0.06, 0.30), (1320, 1320, 0.10, 0.32)],         # two-note "ta-da"
    "chirp-lock":      [(820, 820, 0.05, 0.30), (0, 0, 0.04, 0.0), (820, 1180, 0.11, 0.32)],  # tap · latch
    "chirp-clipboard": [(1000, 1000, 0.05, 0.26), (1380, 1380, 0.06, 0.28)],       # quick double: "saved"
    "chirp-learn":     [(1180, 1520, 0.10, 0.30), (1520, 1900, 0.10, 0.28)],       # bright rising: "learned"
}


def synth(path, segments):
    frames = bytearray()
    for (f0, f1, dur, gain) in segments:
        n = max(1, int(SR * dur))
        for i in range(n):
            frac = i / max(1, n - 1)
            f = f0 + (f1 - f0) * frac
            env = math.sin(math.pi * frac)          # smooth fade in + out (no clicks)
            s = gain * env * math.sin(2 * math.pi * f * (i / SR))
            frames += struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767))
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(bytes(frames))


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, segs in EARCONS.items():
        wav = f"/tmp/talkie-earcon-{name}.wav"
        synth(wav, segs)
        subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16", wav, os.path.join(OUT, f"{name}.caf")], check=True)
        os.remove(wav)
    print(f"generated {len(EARCONS)} earcons into {OUT}")


if __name__ == "__main__":
    main()
