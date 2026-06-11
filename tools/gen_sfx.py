#!/usr/bin/env python3
"""Synthesize the game's sound effects. Python 3 stdlib only.

Usage:  python3 tools/gen_sfx.py

Writes 44.1 kHz / 16-bit / mono WAVs into game/assets/sfx/:
  kick.wav          0.15 s  60-90 Hz thump + boot click
  bounce.wav        0.12 s  soft grass thud
  whistle.wav       ~0.5 s  single referee blast (~2.1 kHz pea trill)
  whistle2.wav      ~0.75 s double blast
  whistle_long.wav  ~1.45 s long full-time blast
  crowd.wav         8 s     loopable stadium murmur (filtered noise + swells)
  cheer.wav         3 s     goal roar swell
"""

import math
import os
import random
import struct
import wave

SR = 44100
OUT_DIR = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "game", "assets", "sfx"))

TWO_PI = 2.0 * math.pi


# ---------------------------------------------------------------- utilities

def write_wav(name, samples, peak=0.85):
    """Normalize to `peak` and write 16-bit mono WAV."""
    m = max(1e-9, max(abs(s) for s in samples))
    k = peak / m
    path = os.path.join(OUT_DIR, name)
    frames = bytearray()
    for s in samples:
        v = int(max(-1.0, min(1.0, s * k)) * 32767.0)
        frames += struct.pack("<h", v)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(bytes(frames))
    print("wrote %-18s %5.2f s  %7d bytes" %
          (name, len(samples) / SR, os.path.getsize(path)))


def lowpass(samples, cutoff):
    """One-pole IIR low-pass."""
    a = math.exp(-TWO_PI * cutoff / SR)
    b = 1.0 - a
    y = 0.0
    out = []
    for s in samples:
        y = b * s + a * y
        out.append(y)
    return out


def highpass(samples, cutoff):
    lp = lowpass(samples, cutoff)
    return [s - l for s, l in zip(samples, lp)]


def bandpass(samples, lo, hi):
    return highpass(lowpass(samples, hi), lo)


def fade_edges(samples, fade_in=0.003, fade_out=0.025):
    """In-place linear edge fades to kill clicks. NOT for loopable sounds."""
    n = len(samples)
    fi = min(int(fade_in * SR), n)
    fo = min(int(fade_out * SR), n)
    for i in range(fi):
        samples[i] *= i / max(1, fi)
    for i in range(fo):
        samples[n - 1 - i] *= i / max(1, fo)
    return samples


def silence(dur):
    return [0.0] * int(dur * SR)


# ------------------------------------------------------------------- sounds

def gen_kick():
    """0.15 s: pitch-dropping 90->60 Hz sine thump + short boot click."""
    dur = 0.15
    n = int(dur * SR)
    rng = random.Random(7)
    click = bandpass([rng.uniform(-1, 1) for _ in range(n)], 1800.0, 7000.0)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / SR
        f = 60.0 + 30.0 * math.exp(-t * 28.0)        # 90 Hz -> 60 Hz
        phase += TWO_PI * f / SR
        thump = math.sin(phase) * math.exp(-t * 20.0)
        c = click[i] * math.exp(-t * 350.0) * 0.7    # leather snap, first ~10 ms
        out.append(math.tanh((thump + c) * 1.6))     # soft clip for punch
    return fade_edges(out, 0.001, 0.02)


def gen_bounce():
    """0.12 s soft thud: 120->70 Hz drop, gentler attack, touch of grass noise."""
    dur = 0.12
    n = int(dur * SR)
    rng = random.Random(3)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / SR
        f = 70.0 + 50.0 * math.exp(-t * 40.0)
        phase += TWO_PI * f / SR
        env = math.exp(-t * 28.0) * min(1.0, t / 0.004)
        s = math.sin(phase) * env
        s += rng.uniform(-1, 1) * 0.12 * math.exp(-t * 120.0)
        out.append(s)
    return fade_edges(out, 0.001, 0.02)


def _whistle_blast(dur, trill_depth=0.55, drop_tail=False, seed=11):
    """Pea whistle: ~2.1 kHz carrier, ~42 Hz pea trill (AM + slight FM)."""
    n = int(dur * SR)
    rng = random.Random(seed)
    breath = bandpass([rng.uniform(-1, 1) for _ in range(n)], 1500.0, 3500.0)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / SR
        atk = min(1.0, t / 0.012)
        rel = min(1.0, (dur - t) / 0.05)
        vib = math.sin(TWO_PI * 42.0 * t + 0.8 * math.sin(TWO_PI * 6.0 * t))
        f = 2100.0 * (1.0 + 0.012 * vib)
        if drop_tail:  # breath dying at the end of a long blast
            rel_t = max(0.0, (t - (dur - 0.18)) / 0.18)
            f *= 1.0 - 0.04 * rel_t
        phase += TWO_PI * f / SR
        am = 1.0 - trill_depth * (0.5 + 0.5 * vib)
        s = math.sin(phase) * 0.85 + 0.22 * math.sin(2.0 * phase)
        s += breath[i] * 0.18
        out.append(s * atk * rel * am)
    return fade_edges(out, 0.002, 0.03)


def gen_whistle():
    return _whistle_blast(0.45) + silence(0.06)


def gen_whistle2():
    return (_whistle_blast(0.22, seed=12) + silence(0.12)
            + _whistle_blast(0.3, seed=13) + silence(0.06))


def gen_whistle_long():
    return _whistle_blast(1.35, trill_depth=0.62, drop_tail=True, seed=14) + silence(0.08)


def gen_crowd():
    """8 s loopable murmur: filtered noise bed + mid chatter, LFO swells whose
    periods divide 8 s; the noise seam is hidden with a 1 s tail->head crossfade."""
    dur = 8.0
    xfade = 1.0
    n = int(dur * SR)
    total = n + int(xfade * SR)
    rng = random.Random(99)
    base = highpass(lowpass([rng.uniform(-1, 1) for _ in range(total)], 420.0), 90.0)
    chat = bandpass([rng.uniform(-1, 1) for _ in range(total)], 600.0, 1800.0)
    out = []
    for i in range(total):
        t = i / SR
        # LFO periods 4 s, 8/3 s, 2 s all divide 8 s -> seamless swells.
        lfo = (0.6 + 0.25 * math.sin(TWO_PI * t / 4.0)
               + 0.15 * math.sin(TWO_PI * t / (8.0 / 3.0) + 1.7))
        ch = 0.18 * (0.7 + 0.3 * math.sin(TWO_PI * t / 2.0 + 0.5))
        out.append(base[i] * lfo + chat[i] * ch)
    res = out[:n]
    fade = int(xfade * SR)
    for i in range(fade):  # crossfade loop tail into the head
        k = i / fade
        res[i] = res[i] * k + out[n + i] * (1.0 - k)
    return res


def gen_cheer():
    """3 s goal roar: band-passed noise swelling fast, fluttering, dying away."""
    dur = 3.0
    n = int(dur * SR)
    rng = random.Random(5)
    roar = bandpass([rng.uniform(-1, 1) for _ in range(n)], 200.0, 1400.0)
    hiss = bandpass([rng.uniform(-1, 1) for _ in range(n)], 2000.0, 6000.0)
    out = []
    for i in range(n):
        t = i / SR
        attack = min(1.0, (t / 0.5) ** 1.5)
        decay = 1.0 if t < 1.2 else math.exp(-(t - 1.2) * 1.5)
        tail = min(1.0, (dur - t) / 0.25)
        flutter = (1.0 + 0.12 * math.sin(TWO_PI * 7.0 * t)
                   + 0.08 * math.sin(TWO_PI * 3.3 * t + 1.0))
        out.append((roar[i] + 0.35 * hiss[i]) * attack * decay * tail * flutter)
    return fade_edges(out, 0.01, 0.05)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    write_wav("kick.wav", gen_kick(), peak=0.9)
    write_wav("bounce.wav", gen_bounce(), peak=0.6)
    write_wav("whistle.wav", gen_whistle(), peak=0.75)
    write_wav("whistle2.wav", gen_whistle2(), peak=0.75)
    write_wav("whistle_long.wav", gen_whistle_long(), peak=0.75)
    write_wav("crowd.wav", gen_crowd(), peak=0.5)
    write_wav("cheer.wav", gen_cheer(), peak=0.85)
    print("done -> %s" % OUT_DIR)


if __name__ == "__main__":
    main()
