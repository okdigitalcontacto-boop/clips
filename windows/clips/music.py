# Clips para Windows · © 2026 OK Digital. Todos los derechos reservados.
"""Música de fondo compuesta en el momento (sin archivos ni derechos de terceros) y canciones propias."""
from __future__ import annotations

from pathlib import Path

import numpy as np

from .util import settings, run, CancelToken, NEVER

SR = 48000
MOODS = ["Calma", "Energía"]


def _hz(n: float) -> float:
    return 440.0 * 2 ** ((n - 69) / 12)


def compose_music(mood: str, seconds: float, seed: int) -> np.ndarray:
    """Compone un tema estéreo de `seconds` segundos (float32, 48 kHz). La semilla hace que cada clip tenga
    su tema y que suene igual al volver a montarlo."""
    calm = mood != "Energía"
    n = int((seconds + 1) * SR)
    L = np.zeros(n, np.float32)
    R = np.zeros(n, np.float32)
    rng = np.random.default_rng(seed)
    noise = np.random.default_rng(seed ^ 0xABCDEF)

    bpm = (78.0 + rng.integers(8)) if calm else (108.0 + rng.integers(10))
    beat = 60 / bpm
    bar = beat * 4
    root = float(rng.choice([57, 60, 62, 65, 55]))  # La, Do, Re, Fa, Sol
    # Acordes en semitonos sobre la tónica (tonalidad mayor).
    I, ii, IV, V, vi = [0, 4, 7, 11], [2, 5, 9, 12], [5, 9, 12, 16], [7, 11, 14, 17], [9, 12, 16, 19]
    progs = [[I, vi, ii, V], [I, vi, IV, V], [IV, I, vi, V]] if calm else [[vi, IV, I, V], [I, V, vi, IV], [IV, V, vi, I]]
    progression = progs[int(rng.integers(len(progs)))]

    def add(start: float, length: float, pan: float, wave: np.ndarray):
        s0 = int(start * SR)
        if s0 >= n:
            return
        m = min(len(wave), n - s0)
        if m <= 0:
            return
        w = wave[:m]
        tail = 0.012 * SR  # salida suave: sin chasquidos al acabar la nota
        w = w * np.minimum(1, (len(wave) - np.arange(m)) / tail)
        L[s0:s0 + m] += (w * min(1, 1 - pan)).astype(np.float32)
        R[s0:s0 + m] += (w * min(1, 1 + pan)).astype(np.float32)

    def tarr(length: float) -> np.ndarray:
        return np.arange(int(length * SR)) / SR

    two_pi = 2 * np.pi

    def keys(t0, dur, note, vel, pan):
        f, t = _hz(note), tarr(dur + 0.4)
        env = np.minimum(1, t / 0.008) * np.exp(-t / (1.6 if calm else 0.9)) * np.where(t > dur, np.exp(-(t - dur) / 0.12), 1)
        trem = 0.92 + 0.08 * np.sin(two_pi * 5 * t)
        tone = np.sin(two_pi * f * t) + 0.22 * np.sin(two_pi * 2 * f * t) * np.exp(-t * 4) + 0.08 * np.sin(two_pi * 3 * f * t) * np.exp(-t * 7)
        add(t0, dur + 0.4, pan, tone * env * trem * vel)

    def pad(t0, dur, note, vel):
        f, t = _hz(note), tarr(dur + 0.6)
        env = np.minimum(1, t / 0.45) * np.where(t > dur, np.exp(-(t - dur) / 0.3), 1)
        add(t0, dur + 0.6, 0, (np.sin(two_pi * f * 0.997 * t) + np.sin(two_pi * f * 1.003 * t)) * 0.5 * env * vel)

    def bass(t0, dur, note, vel):
        f, t = _hz(note), tarr(dur + 0.1)
        env = np.minimum(1, t / 0.01) * np.exp(-t / 1.2) * np.where(t > dur, np.exp(-(t - dur) / 0.05), 1)
        x = np.sin(two_pi * f * t) + 0.3 * np.sin(two_pi * 2 * f * t)
        add(t0, dur + 0.1, 0, np.tanh(x * 1.4) * env * vel)

    def kick(t0, vel):
        t = tarr(0.35)
        # Frecuencia que cae de 126 a 46 Hz: la fase es su integral.
        phase = 46 * t + 80 * (1 - np.exp(-t * 32)) / 32
        add(t0, 0.35, 0, np.sin(two_pi * phase) * np.exp(-t * 8) * vel)

    smooth = 0.45 * 0.55 ** np.arange(64)  # ruido suavizado: menos áspero

    def snare(t0, vel):
        t = tarr(0.2)
        w = noise.random(len(t)) * 2 - 1
        last = np.convolve(w, smooth)[:len(t)]
        add(t0, 0.2, 0.05, (last * np.exp(-t * 20) * 0.7 + np.sin(two_pi * 185 * t) * np.exp(-t * 28) * 0.35) * vel)

    def hat(t0, vel):
        t = tarr(0.06)
        w = noise.random(len(t)) * 2 - 1
        hp = np.diff(w, prepend=0.0)  # agudos: solo el "tss"
        add(t0, 0.06, 0.3, hp * np.exp(-t * 70) * vel)

    bars = int(np.ceil(seconds / bar)) + 1
    for b in range(bars):
        t = b * bar
        chord = progression[b % len(progression)]
        # Acordes: pad en calma, teclas en energía
        for c in chord:
            if calm:
                pad(t, bar, root + c, 0.05)
            keys(t, bar * 0.9 if calm else beat * 1.5, root + c, 0.05 if calm else 0.06, -0.1)
            if not calm:
                keys(t + beat * 2, beat * 1.5, root + c, 0.045, -0.1)
        # Bajo: tónica del acorde dos octavas abajo
        bn = root + chord[0] - 24
        if calm:
            bass(t, beat * 2.6, bn, 0.22)
            bass(t + beat * 2.5, beat * 1.4, bn, 0.16)
        else:
            for k in range(4):
                bass(t + k * beat, beat * 0.85, bn + (7 if k == 3 else 0), 0.2)
        # Arpegio por encima, suave, con algo de variación
        arp = chord + [chord[1] + 12]
        steps = 8 if calm else 16
        for s in range(steps):
            if rng.random() > (0.35 if calm else 0.3):
                keys(t + s * bar / steps, bar / steps, root + 12 + arp[int(rng.integers(len(arp)))], 0.028 if calm else 0.022, 0.25)
        # Batería
        if calm:
            kick(t, 0.5); kick(t + beat * 2.5, 0.38)
            snare(t + beat, 0.16); snare(t + beat * 3, 0.16)
            for h in range(8):
                hat(t + h * beat / 2 + (beat * 0.08 if h % 2 == 1 else 0), 0.045 if h % 2 == 0 else 0.028)
        else:
            for k in range(4):
                kick(t + k * beat, 0.55)
            snare(t + beat, 0.24); snare(t + beat * 3, 0.24)
            for h in range(8):
                hat(t + h * beat / 2 + beat / 4, 0.06)

    # Master: paso bajo suave (más cálido en calma), saturación ligera y normalizar a -3 dBFS.
    cutoff = 5200.0 if calm else 9000.0
    a = 1 - np.exp(-2 * np.pi * cutoff / SR)
    lp = (a * (1 - a) ** np.arange(64)).astype(np.float32)
    out = np.stack([np.tanh(np.convolve(L, lp)[:n] * 1.2), np.tanh(np.convolve(R, lp)[:n] * 1.2)], axis=1)
    peak = max(float(np.abs(out).max()), 1e-4)
    return (out * (0.7 / peak)).astype(np.float32)


AUDIO_EXT = {".mp3", ".m4a", ".wav", ".aac", ".aiff", ".aif", ".flac", ".ogg", ".opus", ".wma"}


def own_music_files() -> list[Path]:
    """Canciones propias de la persona (Ajustes → Música de fondo). Vacío si no ha elegido carpeta."""
    p = settings.get("musicDir") or ""
    if not p:
        return []
    try:
        return sorted(f for f in Path(p).iterdir() if f.suffix.lower() in AUDIO_EXT)
    except OSError:
        return []


def decode_audio(path: Path, seconds: float | None = None, start: float = 0, token: CancelToken = NEVER) -> np.ndarray:
    """Audio de un archivo como float32 estéreo a 48 kHz."""
    args = ["-v", "error"]
    if start > 0:
        args += ["-ss", f"{start:.3f}"]
    args += ["-i", str(path)]
    if seconds is not None:
        args += ["-t", f"{seconds:.3f}"]
    args += ["-vn", "-ac", "2", "-ar", str(SR), "-f", "f32le", "-"]
    data = run("ffmpeg", args, token=token)
    return np.frombuffer(data, np.float32).reshape(-1, 2).copy()
