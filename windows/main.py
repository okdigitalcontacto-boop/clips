# Clips para Windows · © 2026 OK Digital. Todos los derechos reservados.
"""Punto de entrada.

    Clips.exe                                   abre la ventana
    Clips.exe --test <enlace> [nº clips] [--horizontal] [--sin-subtitulos] [--dur 0|1|2] [--notas "texto"] [--log archivo]
                                                proceso completo sin ventana (mismo camino que el botón)
    Clips.exe --selftest [--log archivo]        comprueba herramientas y monta un clip de prueba sin internet
"""
from __future__ import annotations

import multiprocessing
import sys
import time


def _logger(args):
    path = args[args.index("--log") + 1] if "--log" in args and args.index("--log") + 1 < len(args) else None
    fh = open(path, "w", encoding="utf-8") if path else None

    def log(s: str):
        line = str(s)
        try:
            print(line, flush=True)
        except Exception:
            pass
        if fh:
            fh.write(line + "\n")
            fh.flush()
    return log


def test(args) -> int:
    from clips.app import Model
    from clips.util import settings

    settings.persist = False
    log = _logger(args)
    m = Model()
    m.log = log
    rest = [a for a in args[2:]]
    count = int(rest[1]) if len(rest) > 1 and rest[1].isdigit() else 3
    settings.values.update(count=count, vertical="--horizontal" not in args, subtitles="--sin-subtitulos" not in args)
    if "--dur" in args:
        settings.values["durIdx"] = int(args[args.index("--dur") + 1])
    notes = args[args.index("--notas") + 1] if "--notas" in args else ""
    m.start(args[2], notes)
    time.sleep(0.3)
    while m.running:
        time.sleep(0.2)
    if m.error:
        log(f"ERROR: {m.error.message}")
        return 1
    from clips.util import fmt
    for c in m.clips:
        log(f"#{c.rank} [{c.m.score}] {fmt(c.m.start, True)}–{fmt(c.m.end, True)} ({c.duration:.1f}s) | {c.m.title} | {c.m.reason} | {c.file or c.state}")
    return 0 if m.ready_count else 1


def main() -> int:
    args = sys.argv
    if len(args) >= 3 and args[1] == "--test":
        return test(args)
    if len(args) >= 2 and args[1] == "--selftest":
        from clips.selftest import selftest
        return selftest(_logger(args))
    from clips.app import main_window
    main_window()
    return 0


if __name__ == "__main__":
    multiprocessing.freeze_support()
    sys.exit(main())
