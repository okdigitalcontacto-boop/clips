# Clips para Windows · © 2026 OK Digital. Todos los derechos reservados.
"""Orquestador (lo mismo que hace la app de Mac), servidor local de la interfaz y ventana."""
from __future__ import annotations

import atexit
import http.server
import json
import mimetypes
import os
import shutil
import sys
import threading
import time
import traceback
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import unquote, urlparse

import requests

from . import core
from .core import ClipPlan, Moment, Word
from .music import MOODS, own_music_files
from .render import SECTION_MARGIN, RenderOptions, VideoSection, download_section, probe, render_clip, thumbnail
from .util import (APP_NAME, COPYRIGHT, VERSION, WINDOWS, Cancelled, CancelToken, ClipsError, cache_root, clipboard_get,
                   clipboard_set, fmt, local_dir, open_folder, open_url, procs, resource_dir, reveal, run, safe_name,
                   settings, tool_path, videos_dir)

DURATIONS = [(15, 30), (30, 60), (60, 90)]
FOCUSES = list(core.FOCUS.keys())
STAGES = ["video", "text", "moments", "clips"]

PLATFORMS = {
    "YouTube": ("https://www.youtube.com/upload", "Arrastra el clip a la página. Al ser vertical y corto, YouTube lo publica como Short."),
    "Instagram": ("https://www.instagram.com/", "Pulsa «+ Crear» y arrastra el clip. Los vídeos se publican como Reel."),
    "TikTok": ("https://www.tiktok.com/upload", "Arrastra el clip a la página de subida."),
}


# MARK: - Archivos que ve la interfaz (miniaturas y clips), servidos en local

class Media:
    def __init__(self) -> None:
        self.files: dict[str, Path] = {}
        self.lock = threading.Lock()

    def url(self, path: Path | None, version: int = 0) -> str | None:
        if not path:
            return None
        key = uuid.uuid5(uuid.NAMESPACE_URL, str(path)).hex
        with self.lock:
            self.files[key] = path
        return f"/media/{key}{path.suffix}?v={version}"

    def get(self, key: str) -> Path | None:
        with self.lock:
            return self.files.get(key)


media = Media()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        path = unquote(urlparse(self.path).path)
        if path.startswith("/media/"):
            f = media.get(Path(path[7:]).stem)
        elif path.startswith("/ui/"):
            base = (resource_dir() / "ui").resolve()
            f = (base / path[4:]).resolve()
            if base not in f.parents and f != base:
                f = None
        else:
            f = None
        if not f or not f.is_file():
            self.send_error(404)
            return
        size = f.stat().st_size
        ctype = mimetypes.guess_type(str(f))[0] or "application/octet-stream"
        if f.suffix == ".js":
            ctype = "text/javascript; charset=utf-8"
        rng = self.headers.get("Range")
        start, end = 0, size - 1
        if rng and rng.startswith("bytes="):
            a, _, b = rng[6:].split(",")[0].partition("-")
            if a:
                start, end = int(a), int(b) if b else size - 1
            elif b:
                start = max(0, size - int(b))
            end = min(end, size - 1)
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            with open(f, "rb") as fh:
                fh.seek(start)
                left = end - start + 1
                while left > 0:
                    chunk = fh.read(min(1 << 20, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


def start_server() -> int:
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv.server_address[1]


def replace_file(src: Path, dest: Path) -> Path:
    """Pone el clip en su sitio. En Windows un archivo abierto (el reproductor) no se puede sustituir:
    se reintenta un momento y, si sigue ocupado, se guarda con otro nombre."""
    for _ in range(10):
        try:
            os.replace(src, dest)
            return dest
        except PermissionError:
            time.sleep(0.3)
        except OSError:
            break
    n = 2
    while True:
        alt = dest.with_name(f"{dest.stem} ({n}){dest.suffix}")
        if not alt.exists():
            shutil.move(str(src), alt)
            return alt
        n += 1


# MARK: - Estado de cada clip


def reserve_dir(root: Path, name: str) -> Path:
    """Crea root/name (o «name (2)», «name (3)»…) y comprueba que de verdad se puede escribir dentro."""
    root.mkdir(parents=True, exist_ok=True)
    base = root / name
    out, n = base, 2
    while True:
        try:
            out.mkdir()
            break
        except FileExistsError:
            out = Path(f"{base} ({n})")
            n += 1
    try:
        probe_file = out / ".clips"
        probe_file.write_bytes(b"")
        probe_file.unlink()
    except OSError:
        shutil.rmtree(out, ignore_errors=True)
        raise
    return out

class ClipItem:
    def __init__(self, rank: int, m: Moment, options: RenderOptions):
        self.id = uuid.uuid4().hex
        self.rank = rank
        self.m = m
        self.options = options
        self.state = "queued"  # queued, downloading, rendering, ready, failed
        self.progress = 0.0
        self.error = ""
        self.file: Path | None = None
        self.thumb: Path | None = None
        self.section: VideoSection | None = None
        # Sube cada vez que se vuelve a montar, para recargar el reproductor.
        self.version = 0

    @property
    def duration(self) -> float:
        return self.m.end - self.m.start

    @property
    def busy(self) -> bool:
        return self.state in ("queued", "downloading", "rendering")

    def to_json(self) -> dict:
        return {"id": self.id, "rank": self.rank, "title": self.m.title, "reason": self.m.reason, "caption": self.m.caption,
                "score": self.m.score, "start": self.m.start, "end": self.m.end, "state": self.state,
                "progress": self.progress, "error": self.error, "version": self.version,
                "thumb": media.url(self.thumb, self.version), "file": media.url(self.file, self.version),
                "fileName": self.file.name if self.file else None}


# MARK: - Orquestador

class Model:
    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.push = lambda state: None
        self.log = lambda s: None
        self.url = ""
        self.notes = ""
        self.running = False
        self.stage: str | None = None
        self.done: set[str] = set()
        self.detail = ""
        self.error: ClipsError | None = None
        self.info: core.VideoInfo | None = None
        self.curve: list[float] = []
        self.curve_is_heat = True
        self.analyzing = False
        self.clips: list[ClipItem] = []
        self.out_dir: Path | None = None
        self.finished = False
        self.notice: str | None = None
        self.updating_tools = False
        self.chronological = False
        self.words: list[Word] = []
        self.job_url = ""
        self.workdir: Path | None = None
        self.token = CancelToken()
        self.job: threading.Thread | None = None
        self.on_finished = lambda: None
        self._dirty = threading.Event()
        threading.Thread(target=self._pusher, daemon=True).start()

    # Opciones (se guardan entre sesiones, como en la app de Mac)
    def options(self) -> dict:
        return {"count": settings.get("count", 5), "durIdx": settings.get("durIdx", 1), "vertical": settings.get("vertical", True),
                "subtitles": settings.get("subtitles", True), "focus": settings.get("focus", "Automático"),
                "music": settings.get("music", True), "mood": settings.get("mood", "Calma"), "hook": settings.get("hook", True)}

    @property
    def output_base(self) -> Path:
        p = settings.get("outputDir") or ""
        return Path(p) if p else videos_dir() / "Clips"

    # MARK: Envío de estado a la interfaz (como mucho 15 veces por segundo)

    def changed(self) -> None:
        self._dirty.set()

    def _pusher(self) -> None:
        while True:
            self._dirty.wait()
            self._dirty.clear()
            try:
                self.push(self.snapshot())
            except Exception:
                pass
            time.sleep(1 / 15)

    def snapshot(self) -> dict:
        with self.lock:
            i = self.info
            e = self.error
            return {
                "url": self.url, "running": self.running, "stage": self.stage, "done": sorted(self.done), "detail": self.detail,
                "error": {"message": e.message, "canUpdateTools": e.can_update_tools, "opensSettings": e.opens_settings} if e else None,
                "info": {"title": i.title, "channel": i.channel, "duration": i.duration, "thumbnail": i.thumbnail} if i else None,
                "curve": self.curve, "curveIsHeat": self.curve_is_heat, "analyzing": self.analyzing,
                "clips": [c.to_json() for c in self.clips], "outDir": str(self.out_dir) if self.out_dir else None,
                "finished": self.finished, "notice": self.notice, "updatingTools": self.updating_tools,
                "chronological": self.chronological, "readyCount": self.ready_count,
                "words": self.words[-1].end if self.words else 0,
            }

    @property
    def ready_count(self) -> int:
        return sum(1 for c in self.clips if c.state == "ready")

    def fail(self, e: ClipsError) -> None:
        with self.lock:
            self.error = e
        self.changed()

    def enter(self, stage: str, text: str) -> None:
        with self.lock:
            if self.stage and self.stage != stage:
                self.done.add(self.stage)
            self.stage, self.detail = stage, text
        self.log(text)
        self.changed()

    def set_detail(self, text: str) -> None:
        with self.lock:
            self.detail = text
        self.changed()

    def clip(self, cid: str) -> ClipItem | None:
        with self.lock:
            return next((c for c in self.clips if c.id == cid), None)

    # MARK: Acciones

    def start(self, url: str, notes: str = "") -> None:
        with self.lock:
            if self.running:
                return
            raw = url.strip()
            self.url, self.notes = raw, notes
            if not raw:
                return
            link = core.extract_youtube_link(raw)
            if not link:
                self.fail(ClipsError("Eso no es un enlace de YouTube. Copia la dirección del vídeo (youtube.com o youtu.be) y pégala aquí."))
                return
            self.url = link
            problem = core.youtube_link_problem(link)
            if problem:
                self.fail(ClipsError(problem))
                return
            # Sin clave no merece la pena empezar a descargar nada.
            if not core.gemini_key():
                self.fail(core.missing_key_error())
                return
            self.running = True
            self.token = CancelToken()
        self.changed()
        self.job = threading.Thread(target=self.go, args=(link,), daemon=True)
        self.job.start()

    def cancel(self) -> None:
        self.token.event.set()
        procs.kill_all()

    def reset(self) -> None:
        with self.lock:
            self.info, self.clips, self.error, self.stage, self.done, self.detail = None, [], None, None, set(), ""
            self.curve, self.finished, self.out_dir, self.notice = [], False, None, None
        self.changed()

    # MARK: Proceso completo

    def go(self, link: str) -> None:
        token = self.token
        with self.lock:
            self.job_url = link
            self.error, self.clips, self.info, self.stage, self.done, self.curve = None, [], None, None, set(), []
            self.finished, self.out_dir, self.notice, self.chronological = False, None, None, False
        if self.workdir:
            shutil.rmtree(self.workdir, ignore_errors=True)
        wd = cache_root() / uuid.uuid4().hex
        wd.mkdir(parents=True, exist_ok=True)
        self.workdir = wd
        t0 = time.time()
        core.gemini_status = lambda text: (self.set_detail(text), self.log("  " + text))
        opts = self.options()
        try:
            self.enter("video", "Leyendo el vídeo…")
            info = core.fetch_info(link, token)
            with self.lock:
                self.info = info
            self.changed()
            self.log(f"  info {time.time() - t0:.1f}s · {info.title} · {info.duration:.0f}s · subtítulos: {info.caption_lang or 'no'}")
            min_d, max_d = DURATIONS[opts["durIdx"]]
            if 0 < info.duration < min_d:
                raise ClipsError(f"El vídeo dura {int(info.duration)} s, menos que un clip de {min_d}–{max_d} s. Elige una duración más corta.")

            self.enter("text", "Leyendo lo que se dice…")
            words = core.fetch_words(info, link, wd, token)
            if not words:
                self.enter("text", "Este vídeo no tiene subtítulos: escuchando el audio con Gemini…")
                words = core.transcribe_audio(link, wd, token)
            self.words = words
            self.set_curve(info, words)
            self.log(f"  texto {time.time() - t0:.1f}s · {len(words)} palabras")

            # Notas: se interpretan una vez y el plan manda en número, orden y partes.
            plan = ClipPlan()
            note = self.notes.strip()
            if note:
                self.enter("moments", "Leyendo tus notas…")
                plan = core.plan_from_notes(note, info, words, min_d, token)
                self.log(f"  plan: {plan.summary} · nº {plan.count or '-'} · {'cronológico' if plan.chronological else 'por calidad'} · partes {len(plan.parts)}"
                         + (f" · reglas: {plan.rules}" if plan.rules else ""))
                for i, p in enumerate(plan.parts):
                    self.log(f"    parte {i}: {fmt(p.start)}–{fmt(p.end)} {p.title}")
            asked = plan.count or opts["count"]
            fits = max(1, int(info.duration / min_d)) if info.duration > 0 else asked
            want = min(asked, fits)
            self.enter("moments", f"Entendido: {plan.summary}" if plan.summary else
                       ("Buscando el mejor momento…" if want == 1 else f"Buscando los {want} mejores momentos…"))
            with self.lock:
                self.analyzing = True
            self.changed()

            def approve(candidates: list[Moment], need: int) -> list[Moment]:
                """Revisión y verificación; lo que falle vuelve al editor con el problema concreto (hasta 2 rondas)."""
                self.set_detail(f"Revisando los {len(candidates)} candidatos uno a uno…")
                pending = core.review_moments(info, words, candidates, need, min_d, max_d, plan=plan, log=self.log, token=token)
                good: list[Moment] = []
                for rnd in range(3):
                    if not pending:
                        break
                    self.set_detail("Verificando cada clip: que empiece y acabe bien y que el título sea cierto…" if rnd == 0
                                    else f"Corrigiendo {len(pending)} clips que empezaban o acababan a medias…")
                    ok, failed = core.verify_moments(pending, words, min_d, plan, self.log, token)
                    good += ok
                    enough = len(good) >= need if not plan.parts else \
                        len({m.part for m in good if m.part is not None}) >= len({m.part for m in candidates if m.part is not None})
                    if enough or not failed or rnd == 2:
                        break
                    pending = core.review_moments(info, words, [f[0] for f in failed], need, min_d, max_d, notes=[f[1] for f in failed],
                                                  before=70, after=50, plan=plan, log=self.log, token=token)
                return good

            def choose(good: list[Moment]) -> list[Moment]:
                """Sin solapes; los de más puntuación primero. Con partes, el mejor de cada una."""
                out: list[Moment] = []
                for m in sorted(good, key=lambda m: -m.score):
                    if any(m.start < o.end and m.end > o.start for o in out):
                        continue
                    if m.part is not None and any(o.part == m.part for o in out):
                        continue
                    out.append(m)
                    if not plan.parts and len(out) == want:
                        break
                return out

            candidates = core.pick_candidates(info, words, want, min_d, max_d, opts["focus"], plan, token=token)
            self.log(f"  candidatos {time.time() - t0:.1f}s · {len(candidates)}")
            good = approve(candidates, want)
            moments = choose(good)
            # Partes que se han quedado sin clip: una búsqueda más solo en ellas.
            missing = [p for p in range(len(plan.parts)) if not any(m.part == p for m in moments)]
            if missing:
                self.set_detail("Buscando otra vez en la parte que falta…" if len(missing) == 1 else f"Buscando otra vez en las {len(missing)} partes que faltan…")
                self.log(f"  sin clip en partes {missing}; segunda búsqueda")
                try:
                    more = [m for m in core.pick_candidates(info, words, len(missing), min_d, max_d, opts["focus"], plan, missing, token)
                            if not any(m.start < o.end and m.end > o.start for o in moments)]
                except ClipsError:
                    more = []
                if more:
                    good += approve(more, len(missing))
                moments = choose(good)
                missing = [p for p in range(len(plan.parts)) if not any(m.part == p for m in moments)]
            if plan.chronological:
                moments.sort(key=lambda m: m.start)
            with self.lock:
                self.chronological = plan.chronological
                self.analyzing = False
            self.log(f"  aprobados {time.time() - t0:.1f}s · {len(moments)}")
            if not moments:
                raise ClipsError("Ningún momento ha pasado la revisión (empezaban o acababan a medias, no enganchaban o no cumplían tus notas). "
                                 "Prueba con otra duración, otro enfoque u otras notas.")
            if missing:
                self.notice = "Sin clip en " + ", ".join(f"«{plan.parts[p].title}»" for p in missing) + \
                              ": no había un momento que se entendiera solo y cupiera en la duración."
            elif len(moments) < asked:
                self.notice = (f"El vídeo solo da para {len(moments)} {'clip' if len(moments) == 1 else 'clips'} de esta duración."
                               if info.duration > 0 and fits < asked else
                               f"Solo {len(moments)} de los candidatos han pasado la revisión; prefiero darte menos antes que clips flojos.")

            # Reservar la carpeta. Si Windows no deja escribir en la elegida (raíz de un disco, protección
            # contra ransomware…), se guarda en Vídeos › Clips o en la carpeta del usuario y se avisa.
            chosen = self.output_base
            out = None
            for root in dict.fromkeys([chosen, videos_dir() / "Clips", Path.home() / "Clips"]):
                try:
                    out = reserve_dir(root, safe_name(info.title))
                    break
                except OSError as e:
                    self.log(f"No se puede guardar en {root}: {e}")
            if out is None:
                raise ClipsError("Windows no deja guardar los clips en ninguna carpeta. Elige otra en Ajustes, "
                                 "por ejemplo una dentro de Documentos.", opens_settings=True)
            if out.parent != chosen:
                where = "Vídeos › Clips" if out.parent == videos_dir() / "Clips" else str(out.parent)
                msg = f"Windows no deja guardar en {chosen}, así que los clips van a {where}. Puedes cambiar la carpeta en Ajustes."
                self.notice = f"{self.notice} {msg}" if self.notice else msg
            self.out_dir = out

            ropts = RenderOptions(opts["vertical"], opts["subtitles"], opts["music"], opts["mood"], opts["hook"])
            for i, mo in enumerate(moments):
                with self.lock:
                    self.clips.append(ClipItem(i + 1, mo, RenderOptions(**ropts.__dict__)))
                self.changed()
                token.sleep(0.07)
            self.enter("clips", f"Descargando y montando {len(moments)} clips…")

            ids = [c.id for c in self.clips]
            with ThreadPoolExecutor(3) as pool:
                list(pool.map(lambda cid: self.process(cid, token), ids))
            token.check()
            ok = self.ready_count
            if ok == 0:
                self.remove_out_dir_if_empty()
                raise ClipsError(next((c.error for c in self.clips if c.state == "failed" and c.error), None) or "No se pudo montar ningún clip.")
            with self.lock:
                self.done.add("clips")
                self.finished = True
                self.detail = f"{ok} clips listos" if ok == len(self.clips) else f"{ok} de {len(self.clips)} clips listos"
            self.log(f"  total {time.time() - t0:.1f}s")
            self.on_finished()
        except Cancelled:
            self.cancelled()
        except Exception as e:
            if token.cancelled:
                self.cancelled()
            else:
                self.remove_out_dir_if_empty()
                if not isinstance(e, ClipsError):
                    self.log(traceback.format_exc())
                self.fail(e if isinstance(e, ClipsError) else ClipsError(f"Algo ha fallado: {e}"))
                self.log(f"ERROR: {e}")
        finally:
            with self.lock:
                self.running = False
                self.analyzing = False
            self.changed()

    def remove_out_dir_if_empty(self) -> None:
        """Si no ha salido ningún clip, no dejar una carpeta vacía en Vídeos."""
        d = self.out_dir
        try:
            if d and d.is_dir() and not any(d.iterdir()):
                d.rmdir()
                self.out_dir = None
        except OSError:
            pass

    def cancelled(self) -> None:
        with self.lock:
            self.analyzing = False
            self.remove_out_dir_if_empty()
            for c in self.clips:
                if c.busy:
                    c.state, c.error = "failed", "Cancelado"
            self.detail = "Cancelado"
            if all(c.state != "ready" for c in self.clips):
                self.clips = []
        self.changed()

    def set_curve(self, info: core.VideoInfo, words: list[Word]) -> None:
        if info.heatmap:
            values, heat = [v for _, _, v in info.heatmap], True
        else:
            # Sin datos de YouTube: cuánto se habla en cada tramo.
            bins, d = 80, max(info.duration, words[-1].end if words else 1)
            values = [0.0] * bins
            for w in words:
                if not w.is_tag:
                    values[min(bins - 1, int(w.start / d * bins))] += 1
            mx = max(values) or 1
            values, heat = [v / mx for v in values], False
        with self.lock:
            self.curve, self.curve_is_heat = values, heat
        self.changed()

    def update(self, cid: str, **kw) -> None:
        with self.lock:
            c = next((c for c in self.clips if c.id == cid), None)
            if c:
                for k, v in kw.items():
                    setattr(c, k, v)
        self.changed()

    def process(self, cid: str, token: CancelToken) -> None:
        """Descarga el trozo de un clip y lo monta. Si falla, solo falla ese clip."""
        c = self.clip(cid)
        wd, out_dir = self.workdir, self.out_dir
        if not c or not wd or not out_dir:
            return
        dur = self.info.duration if self.info else 0
        # El guion de subtítulos se pide ya, en paralelo con la descarga.
        in_clip = [w for w in self.words if c.m.start - 0.1 <= w.start < c.m.end]
        script_box: dict = {}
        script_thread = None
        if c.options.subtitles:
            script_thread = threading.Thread(target=lambda: script_box.update(v=core.subtitle_script(in_clip, c.options.vertical, c.m.title, token)), daemon=True)
            script_thread.start()
        try:
            sec = c.section
            if not (sec and sec.start <= c.m.start + 0.01 and sec.end >= c.m.end - 0.01):
                self.update(cid, state="downloading", progress=0.0)
                end = min(dur, c.m.end + SECTION_MARGIN) if dur > 0 else c.m.end + SECTION_MARGIN
                sec = download_section(self.job_url, c.m.start - SECTION_MARGIN, end, wd, f"s-{cid}", 1440 if c.options.vertical else 1080,
                                       lambda p: self.update(cid, progress=p) if c.state == "downloading" else None, token)
                self.update(cid, section=sec)
            self.update(cid, state="rendering")
            file = c.file or out_dir / f"{c.rank:02d} {safe_name(c.m.title)}.mp4"
            # Música de fondo: canciones propias (Ajustes) o un tema compuesto para este clip.
            song = None
            if c.options.music:
                own = own_music_files()
                if own:
                    song = own[(c.rank - 1) % len(own)]
            seed = c.rank * 7919 + int(max(0, dur) * 10)
            # Subtítulos revisados (palabras bien escritas y líneas por frases).
            if script_thread:
                script_thread.join()
            script = script_box.get("v")
            if c.options.subtitles and script is None:
                self.log(f"  clip {c.rank}: subtítulos sin revisar (Gemini no devolvió un guion válido)")
            token.check()
            tmp = wd / f"r-{cid}.mp4"
            rendered = render_clip(sec, c.m.start, c.m.end, self.words, c.options, c.m.title if c.options.hook else None,
                                   song, seed, script, tmp, wd, token, self.log)
            # Comprobación final antes de entregarlo: que dure lo que debe y tenga imagen y sonido.
            pr = probe(tmp, token)
            if pr.audio_end is None or abs(pr.duration - rendered) >= 1.0 or pr.duration <= 3:
                tmp.unlink(missing_ok=True)
                raise ClipsError("El clip montado no ha pasado la comprobación final (duración o pistas incorrectas).")
            file = replace_file(tmp, file)
            th = thumbnail(file, min(1.5, pr.duration / 3), wd / f"t-{cid}-{c.version + 1}.jpg", token)
            with self.lock:
                c.file, c.thumb, c.state, c.version, c.error = file, th, "ready", c.version + 1, ""
            self.changed()
            self.log(f"  clip {c.rank} listo: {file.name}")
        except Exception as e:
            msg = "Cancelado" if (isinstance(e, Cancelled) or token.cancelled) else (e.message if isinstance(e, ClipsError) else str(e))
            if not isinstance(e, (ClipsError, Cancelled)):
                self.log(traceback.format_exc())
            self.update(cid, state="failed", error=msg)
            self.log(f"  clip {c.rank} falló: {msg}")

    def retry(self, cid: str) -> None:
        threading.Thread(target=self.process, args=(cid, self.token if self.running else CancelToken()), daemon=True).start()

    def retrim(self, cid: str, start: float, end: float) -> None:
        """Cambia inicio o final de un clip ya montado y lo vuelve a montar."""
        c = self.clip(cid)
        if not c or end - start < 1:
            return
        with self.lock:
            c.m.start, c.m.end = max(0.0, start), end
            c.state = "rendering"
        self.changed()
        self.retry(cid)

    def update_tools(self) -> None:
        """Baja el yt-dlp más reciente (YouTube cambia a menudo y hay que ir al día)."""
        if self.updating_tools:
            return
        self.updating_tools = True
        self.changed()

        def work():
            try:
                if WINDOWS:
                    dest = local_dir() / "bin"
                    dest.mkdir(parents=True, exist_ok=True)
                    r = requests.get("https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe", stream=True, timeout=60)
                    r.raise_for_status()
                    tmp = dest / "yt-dlp.exe.part"
                    with open(tmp, "wb") as fh:
                        for chunk in r.iter_content(1 << 20):
                            fh.write(chunk)
                    os.replace(tmp, dest / "yt-dlp.exe")
                else:
                    run("brew", ["upgrade", "yt-dlp"])
                with self.lock:
                    self.error = None
                    self.notice = "yt-dlp está al día. Vuelve a pulsar Sacar clips."
            except Exception:
                self.fail(ClipsError("No he podido actualizar yt-dlp. Comprueba la conexión y vuelve a probar."))
            finally:
                self.updating_tools = False
                self.changed()

        threading.Thread(target=work, daemon=True).start()


# MARK: - Puente con la interfaz (lo que la página puede pedir)

class Api:
    def __init__(self, model: Model):
        self._m = model
        self._window = None

    def state(self):
        return self._m.snapshot()

    def options(self):
        own = bool(own_music_files())
        return {**self._m.options(), "durations": DURATIONS, "focuses": FOCUSES, "moods": MOODS, "ownMusic": own,
                "version": VERSION, "copyright": COPYRIGHT, "sounds": settings.get("sounds", True),
                "outputLabel": self._output_label(), "platforms": {k: v[1] for k, v in PLATFORMS.items()}}

    def _output_label(self):
        p = settings.get("outputDir") or ""
        return "Vídeos › Clips" if not p else (Path(p).name or p)

    def set_option(self, key, value):
        if key in ("count", "durIdx", "vertical", "subtitles", "focus", "music", "mood", "hook", "sounds"):
            settings.set(key, value)

    def start(self, url, notes=""):
        self._m.start(url or "", notes or "")

    def cancel(self):
        self._m.cancel()

    def dismiss_error(self):
        with self._m.lock:
            self._m.error = None
        self._m.changed()

    def clipboard_link(self):
        """Si en el portapapeles hay un enlace de YouTube, para pegarlo solo al abrir o volver a la ventana."""
        return core.extract_youtube_link(clipboard_get() or "")

    def clipboard_text(self):
        return clipboard_get()

    def is_link(self, text):
        return core.extract_youtube_link(text or "")

    def _caption(self, c: ClipItem) -> str:
        return c.m.title if not c.m.caption else f"{c.m.title}\n\n{c.m.caption}"

    def copy_caption(self, cid):
        c = self._m.clip(cid)
        if c:
            clipboard_set(self._caption(c))

    def copy_all(self):
        text = "\n\n".join(f"{c.rank}. {c.m.title}\n{c.m.caption}" for c in self._m.clips if c.state == "ready")
        clipboard_set(text)

    def publish(self, cid, platform):
        """Subida asistida: abre la web de subida de la red, copia el texto y muestra el archivo para arrastrarlo."""
        c = self._m.clip(cid)
        if not c or not c.file or platform not in PLATFORMS:
            return
        clipboard_set(self._caption(c))
        open_url(PLATFORMS[platform][0])
        threading.Timer(0.6, lambda: reveal(c.file)).start()

    def reveal(self, cid):
        c = self._m.clip(cid)
        if c and c.file:
            reveal(c.file)

    def open_folder(self):
        if self._m.out_dir:
            open_folder(self._m.out_dir)

    def retry(self, cid):
        self._m.retry(cid)

    def retrim(self, cid, start, end):
        self._m.retrim(cid, float(start), float(end))

    def update_tools(self):
        self._m.update_tools()

    def open_url(self, url):
        if url.startswith("https://"):
            open_url(url)

    # Ajustes
    def settings(self):
        return {"key": settings.get("geminiKey") or "", "outputDir": settings.get("outputDir") or "",
                "outputDefault": str(videos_dir() / "Clips"), "musicDir": settings.get("musicDir") or "",
                "sounds": settings.get("sounds", True), "version": VERSION, "copyright": COPYRIGHT}

    def set_key(self, key):
        settings.set("geminiKey", (key or "").strip())

    def test_key(self):
        k = core.gemini_key()
        return bool(k) and core.test_gemini_key(k)

    def choose_folder(self, which):
        import webview
        if not self._window:
            return None
        r = self._window.create_file_dialog(webview.FileDialog.FOLDER if hasattr(webview, "FileDialog") else webview.FOLDER_DIALOG)
        if r:
            path = r[0] if isinstance(r, (list, tuple)) else r
            settings.set("outputDir" if which == "output" else "musicDir", path)
            return path
        return None

    def clear_folder(self, which):
        settings.set("outputDir" if which == "output" else "musicDir", "")


# MARK: - Arranque

def cleanup() -> None:
    procs.kill_all()
    shutil.rmtree(cache_root(), ignore_errors=True)


def flash_taskbar(title: str) -> None:
    """Avisa en la barra de tareas cuando termina y la ventana no está delante."""
    if not WINDOWS:
        return
    try:
        import ctypes
        from ctypes import wintypes

        class FLASHWINFO(ctypes.Structure):
            _fields_ = [("cbSize", wintypes.UINT), ("hwnd", wintypes.HWND), ("dwFlags", wintypes.DWORD),
                        ("uCount", wintypes.UINT), ("dwTimeout", wintypes.DWORD)]

        u32 = ctypes.windll.user32
        hwnd = u32.FindWindowW(None, title)
        if hwnd and u32.GetForegroundWindow() != hwnd:
            fi = FLASHWINFO(ctypes.sizeof(FLASHWINFO), hwnd, 0x3 | 0xC, 0, 0)  # FLASHW_ALL | FLASHW_TIMERNOFG
            u32.FlashWindowEx(ctypes.byref(fi))
    except Exception:
        pass


def open_log() -> callable:
    path = local_dir() / "clips.log"
    lock = threading.Lock()

    def log(s: str):
        with lock:
            try:
                with open(path, "a", encoding="utf-8") as fh:
                    fh.write(time.strftime("%H:%M:%S ") + s + "\n")
            except OSError:
                pass
    try:
        if path.exists() and path.stat().st_size > 2_000_000:
            path.unlink()
    except OSError:
        pass
    return log


def main_window() -> None:
    import webview

    atexit.register(cleanup)
    model = Model()
    api = Api(model)
    file_log = open_log()
    model.log = file_log
    port = start_server()
    window = webview.create_window(APP_NAME, f"http://127.0.0.1:{port}/ui/index.html", js_api=api,
                                   width=960, height=860, min_size=(800, 680), background_color="#F4F4F6", text_select=True)
    api._window = window

    def push(state):
        try:
            window.evaluate_js(f"window.app && window.app.update({json.dumps(state)})")
        except Exception:
            pass
    model.push = push
    model.on_finished = lambda: flash_taskbar(APP_NAME)
    window.events.closed += cleanup
    webview.start(debug=bool(os.environ.get("CLIPS_DEBUG")), private_mode=False, storage_path=str(local_dir() / "WebView"))
