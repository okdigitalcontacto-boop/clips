# Clips para Windows · © 2026 OK Digital. Todos los derechos reservados.
"""Prueba sin internet: herramientas presentes, fuentes, detector de caras y un clip montado de punta a punta."""
from __future__ import annotations

import shutil
import time
import uuid

from .core import Word
from .render import RenderOptions, VideoSection, probe, render_clip, thumbnail
from .util import cache_root, run, tool_path, VERSION


def selftest(log) -> int:
    ok = True
    log(f"Clips {VERSION} · prueba")
    for t in ("yt-dlp", "ffmpeg", "ffprobe", "deno"):
        p = tool_path(t)
        if not p:
            log(f"FALTA {t}")
            ok = False
            continue
        flag = "-version" if t.startswith("ff") else "--version"
        try:
            v = run(t, [flag]).decode("utf-8", "replace").splitlines()[0]
        except Exception as e:
            v = f"no arranca: {e}"
            ok = False
        log(f"  {t}: {v}")
    wd = cache_root() / f"selftest-{uuid.uuid4().hex[:8]}"
    wd.mkdir(parents=True)
    try:
        # Vídeo de prueba: 14 s, 1280×720, sin caras (sale en plano entero sobre fondo difuminado).
        src = wd / "src.mp4"
        run("ffmpeg", ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=14",
                       "-f", "lavfi", "-i", "sine=frequency=220:duration=14", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                       "-c:a", "aac", "-shortest", str(src)])
        text = "Esto es una prueba de Clips en Windows con subtítulos palabra a palabra y música de fondo que baja sola."
        words, t = [], 1.0
        for w in text.split():
            words.append(Word(t, t + 0.32, w))
            t += 0.42
        sec = VideoSection(src, 0, 14)
        for vertical in (True, False):
            t0 = time.time()
            out = wd / f"clip-{'v' if vertical else 'h'}.mp4"
            d = render_clip(sec, 0.5, 13.5, words, RenderOptions(vertical=vertical), "Título de prueba con ñ y tildes", None, 7, None, out, wd, log=log)
            pr = probe(out)
            good = out.exists() and pr.audio_end is not None and abs(pr.duration - d) < 1 and (pr.width, pr.height) == ((1080, 1920) if vertical else (1280, 720))
            ok &= good
            log(f"  montaje {'vertical' if vertical else 'horizontal'}: {'bien' if good else 'MAL'} · {pr.width}×{pr.height} · {pr.duration:.2f} s · {time.time() - t0:.1f} s")
            th = thumbnail(out, 2, wd / f"thumb-{vertical}.jpg")
            ok &= th is not None
    except Exception as e:
        log(f"FALLO: {e}")
        ok = False
    finally:
        shutil.rmtree(wd, ignore_errors=True)
    log("PRUEBA SUPERADA" if ok else "PRUEBA FALLIDA")
    return 0 if ok else 1
