#!/usr/bin/env python3
"""Writes Ambient's sound cues (standard library only). Run: python3 scripts/make-sound-cues.py

Soft mallet tones in D major: a sine with one quick-fading overtone, a 4 ms attack so nothing clicks,
and an exponential tail. Files peak at 0.5; each app sets the playback volume in one place.
"""
import math, struct, wave
from pathlib import Path

RATE = 44_100
OUT = [Path(__file__).resolve().parent.parent / "Packages/AmbientKit/Sources/AmbientUI/Sound/Sounds",
       Path(__file__).resolve().parent.parent / "windows/src/sounds"]
A5, B5, CS5, D6, E5, FS5 = 880.0, 987.77, 554.37, 1174.66, 659.25, 739.99

def note(freq, at, gain=1.0, tau=0.05, glide=1.0, overtone=0.14):
    """glide is the starting frequency ratio; it settles on freq within 25 ms."""
    return (freq, at, gain, tau, glide, overtone)

CUES = {
    "listen": (0.16, [note(A5, 0, tau=0.035, glide=0.96)]),   # recording started: a small upward pop
    "send": (0.18, [note(FS5, 0, tau=0.04, glide=1.04)]),     # request handed over: the same pop, falling
    "attention": (0.42, [note(B5, 0, tau=0.07), note(B5, 0.11, 0.7, tau=0.09)]),  # approval needed
    "complete": (0.55, [note(A5, 0, 0.8, tau=0.07), note(D6, 0.08, tau=0.16)]),   # done, rising fourth
    "error": (0.45, [note(E5, 0, tau=0.07, overtone=0.06), note(CS5, 0.1, 0.85, tau=0.12, overtone=0.06)]),
}

def render(length, notes, peak=0.5):
    n = int(length * RATE)
    out = [0.0] * n
    for freq, at, gain, tau, glide, overtone in notes:
        phase = phase2 = 0.0
        for i in range(int(at * RATE), n):
            t = i / RATE - at
            f = freq * (1 + (glide - 1) * math.exp(-t / 0.008))
            phase += 2 * math.pi * f / RATE
            phase2 += 2 * math.pi * f * 2.0 / RATE
            attack = 0.5 - 0.5 * math.cos(math.pi * min(t / 0.004, 1))
            out[i] += gain * attack * (math.exp(-t / tau) * math.sin(phase)
                                       + overtone * math.exp(-t / (tau * 0.35)) * math.sin(phase2))
    fade = int(0.02 * RATE)
    for i in range(fade):
        out[n - fade + i] *= 1 - i / fade
    scale = peak / max(abs(x) for x in out)
    return [round(x * scale * 32767) for x in out]

for name, (length, notes) in CUES.items():
    samples = render(length, notes)
    for folder in OUT:
        folder.mkdir(parents=True, exist_ok=True)
        with wave.open(str(folder / f"{name}.wav"), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
            w.writeframes(struct.pack(f"<{len(samples)}h", *samples))
