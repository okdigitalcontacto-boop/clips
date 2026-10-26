# Clips para Windows · © 2026 OK Digital. Todos los derechos reservados.
"""Vídeo, transcripción, Gemini y elección de momentos (misma lógica que la versión de Mac)."""
from __future__ import annotations

import json
import os
import queue
import re
import threading
import time
import unicodedata
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlparse, parse_qs

import requests

from .util import ClipsError, Cancelled, CancelToken, NEVER, run, settings, ytdlp_base, fmt


# MARK: - Datos del vídeo

@dataclass
class Word:
    start: float
    end: float
    text: str

    @property
    def is_tag(self) -> bool:
        """Marcas como [Música] o [Risas]: sirven de pista a la IA pero no van en los subtítulos."""
        return self.text.startswith("[") or self.text.startswith("(")


@dataclass
class VideoInfo:
    id: str
    title: str
    channel: str
    duration: float
    heatmap: list  # [(start, end, value)]
    chapters: list  # [(start, title)]
    thumbnail: str | None
    caption_url: str | None
    caption_lang: str | None
    has_word_timing: bool


def is_youtube_link(s: str) -> bool:
    try:
        h = (urlparse(s.strip()).hostname or "").lower()
    except ValueError:
        return False
    return h == "youtu.be" or h == "youtube.com" or h.endswith(".youtube.com")


def extract_youtube_link(s: str) -> str | None:
    """Saca el enlace de YouTube de un texto pegado, aunque venga con más texto alrededor o sin "https://"."""
    text = s.strip()
    if is_youtube_link(text) and " " not in text:
        return text
    for token in re.split(r"[\s<>\"'()]+", text):
        if not token:
            continue
        t = token if token.lower().startswith("http") else "https://" + token
        if is_youtube_link(t):
            return t
    return None


def youtube_link_problem(s: str) -> str | None:
    """Enlaces de YouTube que no son de un vídeo (listas, canales, portada)."""
    u = urlparse(s)
    host = (u.hostname or "").lower()
    if not host:
        return None
    path = u.path.lower()
    if host == "youtu.be":
        return None if len(path) > 1 else "Ese enlace no lleva a ningún vídeo."
    has_video = any(v for v in parse_qs(u.query).get("v", []))
    if has_video or any(path.startswith(p) for p in ("/shorts/", "/live/", "/embed/", "/v/")):
        return None
    if path.startswith("/playlist"):
        return "Es una lista de reproducción. Abre el vídeo que quieras y copia su enlace."
    if path.startswith("/@") or path.startswith("/channel") or path.startswith("/c/") or path.startswith("/user"):
        return "Es el enlace de un canal. Abre uno de sus vídeos y copia su enlace."
    return "Ese enlace no lleva a ningún vídeo. Abre el vídeo en YouTube y copia su enlace."


def fetch_info(url: str, token: CancelToken = NEVER) -> VideoInfo:
    d = run("yt-dlp", ["-J"] + ytdlp_base() + [url], token=token)
    try:
        j = json.loads(d)
    except Exception:
        raise ClipsError("No pude leer los datos del vídeo.")
    if j.get("_type") == "playlist":
        raise ClipsError("Es una lista de reproducción. Abre el vídeo que quieras y copia su enlace.")
    if j.get("is_live") is True:
        raise ClipsError("Es un directo en curso. Espera a que termine y vuelve a probar.")
    subs = {k: v for k, v in (j.get("subtitles") or {}).items() if k != "live_chat"}
    autos = j.get("automatic_captions") or {}
    # Idioma original: el que dice YouTube o, si no, el del audio marcado como original
    # (los vídeos con doblaje automático traen varias pistas de audio y de subtítulos).
    formats = j.get("formats") or []
    audio = [f for f in formats if (f.get("acodec") or "none") != "none" and isinstance(f.get("language"), str)]
    original_audio = max(audio, key=lambda f: f.get("language_preference") if isinstance(f.get("language_preference"), int) else -1)["language"] if audio else None
    lang = j.get("language") if isinstance(j.get("language"), str) else original_audio

    def base(s: str) -> str:
        return s.lower().split("-")[0]

    def json3(lst):
        for x in lst or []:
            if x.get("ext") == "json3" and x.get("url"):
                return x["url"]
        return None

    # Preferencia: subtítulos automáticos en el idioma original (traen el tiempo de cada palabra),
    # luego los subidos por el autor, luego automáticos en el idioma del vídeo.
    cap = None
    origs = sorted(k for k in autos if k.endswith("-orig"))
    orig = next((k for k in origs if lang and base(k) == base(lang)), None) or (origs[0] if (lang is None and origs) else None)
    if orig and json3(autos.get(orig)):
        cap = (json3(autos[orig]), orig, True)
    else:
        k = None
        if lang:
            k = next((s for s in subs if base(s) == base(lang)), None)
        k = k or next((s for s in subs if s.startswith("es")), None) or next((s for s in subs if s.startswith("en")), None) \
            or (sorted(subs)[0] if subs else None)
        if k and json3(subs.get(k)):
            cap = (json3(subs[k]), k, False)
        elif lang:
            k = lang if lang in autos else next((a for a in autos if a == base(lang)), None)
            if k and json3(autos.get(k)):
                cap = (json3(autos[k]), k, True)

    heat = []
    for e in j.get("heatmap") or []:
        try:
            heat.append((float(e["start_time"]), float(e["end_time"]), float(e["value"])))
        except (KeyError, TypeError, ValueError):
            pass
    chapters = []
    for c in j.get("chapters") or []:
        if isinstance(c.get("start_time"), (int, float)) and isinstance(c.get("title"), str):
            chapters.append((float(c["start_time"]), c["title"]))
    return VideoInfo(id=j.get("id") or str(uuid.uuid4()), title=j.get("title") or "Vídeo",
                     channel=j.get("channel") or j.get("uploader") or "", duration=float(j.get("duration") or 0),
                     heatmap=heat, chapters=chapters, thumbnail=j.get("thumbnail"),
                     caption_url=cap[0] if cap else None, caption_lang=cap[1] if cap else None,
                     has_word_timing=cap[2] if cap else False)


# MARK: - Transcripción

def spread(text: str, a: float, b: float) -> list[Word]:
    """Reparte una frase en palabras con el tiempo proporcional a su longitud."""
    parts = [p for p in text.split(" ") if p]
    total = sum(len(p) + 1 for p in parts)
    if total <= 0:
        return []
    t, out = a, []
    for p in parts:
        d = (b - a) * (len(p) + 1) / total
        out.append(Word(t, t + d, p))
        t += d
    return out


def parse_json3(data: bytes) -> list[Word]:
    """Convierte subtítulos json3 de YouTube en palabras con tiempo."""
    try:
        events = json.loads(data).get("events") or []
    except Exception:
        return []
    words: list[Word] = []
    for e in events:
        segs, t0 = e.get("segs"), e.get("tStartMs")
        if not segs or t0 is None:
            continue
        dur = float(e.get("dDurationMs") or 0) / 1000
        start = float(t0) / 1000
        items = []
        for s in segs:
            t = (s.get("utf8") or "").replace("\n", " ").strip()
            if t:
                items.append((start + float(s.get("tOffsetMs") or 0) / 1000, t))
        if not items:
            continue
        if len(items) == 1 and " " in items[0][1]:
            # Subtítulos manuales: una frase entera en un bloque; repartimos el tiempo entre sus palabras.
            words += spread(items[0][1], start, start + max(dur, 0.3))
        else:
            words += [Word(t, t, w) for t, w in items]
    words.sort(key=lambda w: w.start)
    for i, w in enumerate(words):
        if w.end <= w.start:
            nxt = words[i + 1].start if i + 1 < len(words) else w.start + 0.6
            w.end = min(nxt, w.start + 0.9)
    # A veces un bloque trae dos palabras juntas ("of it"): se separan para poder buscarlas y subtitularlas.
    out = []
    for w in words:
        out += spread(w.text, w.start, w.end) if (" " in w.text and not w.is_tag) else [w]
    return out


def transcript_lines(words: list[Word]) -> str:
    """Texto para la IA: una línea por frase o pausa, con el segundo exacto delante."""
    lines, cur, cur_start, last_end = [], [], 0.0, 0.0
    for w in words:
        if cur and (w.start - last_end > 0.8 or w.start - cur_start > 10):
            lines.append(f"[{cur_start:.1f}] " + " ".join(cur))
            cur = []
        if not cur:
            cur_start = w.start
        cur.append(w.text)
        last_end = w.end
    if cur:
        lines.append(f"[{cur_start:.1f}] " + " ".join(cur))
    return "\n".join(lines)


def fetch_words(info: VideoInfo, url: str, workdir: Path, token: CancelToken = NEVER) -> list[Word]:
    if info.caption_url:
        try:
            r = requests.get(info.caption_url, timeout=30)
            if r.status_code == 200:
                w = parse_json3(r.content)
                if w:
                    return w
        except requests.RequestException:
            pass
    token.check()
    # Plan B: que yt-dlp baje los subtítulos (a veces YouTube no deja leerlos directamente).
    if info.caption_lang:
        try:
            run("yt-dlp", ["--skip-download", "--write-subs", "--write-auto-subs", "--sub-langs", info.caption_lang,
                           "--sub-format", "json3"] + ytdlp_base() + ["-o", str(workdir / "sub"), url], token=token)
        except ClipsError:
            pass
        for f in workdir.glob("*.json3"):
            w = parse_json3(f.read_bytes())
            if w:
                return w
    return []


# MARK: - Gemini

# Del mejor al más disponible. Si uno está saturado o tarda, entra el siguiente.
GEMINI_MODELS = ["gemini-3.8-flash", "gemini-3.6-flash", "gemini-3.5-flash", "gemini-3.5-flash-lite"]
API = "https://generativelanguage.googleapis.com"

# Para avisar en pantalla cuando Gemini va saturado y se está reintentando.
gemini_status = None


def missing_key_error() -> ClipsError:
    return ClipsError("Falta la clave de Gemini. Es gratis: ábrela en Ajustes y sigue los 3 pasos.", fatal=True, opens_settings=True)


def gemini_key() -> str:
    k = (settings.get("geminiKey") or "").strip()
    return k or os.environ.get("GEMINI_API_KEY", "").strip()


def _failure(status: int, text: str) -> ClipsError:
    msg = text.lower()
    if status == 429:
        return ClipsError("Gemini ha llegado a su límite gratuito por ahora. Espera un minuto y vuelve a probar.")
    if (status == 400 and "api key" in msg) or status in (401, 403):
        return ClipsError("Gemini no acepta la clave. Revísala en Ajustes.", fatal=True, opens_settings=True)
    if status == 404:
        return ClipsError("Los modelos de Gemini que usa Clips ya no están disponibles; hay que actualizar la app.")
    if status == 503:
        return ClipsError("Gemini está saturado ahora mismo. Vuelve a probar en un par de minutos.")
    return ClipsError(f"Gemini respondió con un error ({status}). Vuelve a probar en un momento.")


def network_error(e: Exception, who: str) -> ClipsError:
    """Traduce los fallos de red a mensajes claros."""
    if isinstance(e, requests.Timeout):
        return ClipsError(f"{who} ha tardado demasiado en responder. Vuelve a probar.")
    if isinstance(e, requests.ConnectionError):
        s = str(e).lower()
        if "getaddrinfo" in s or "name or service" in s or "nodename" in s or "failed to resolve" in s:
            return ClipsError("No hay conexión a internet.", fatal=True)
        return ClipsError(f"Se ha cortado la conexión con {who}. Comprueba internet y vuelve a probar.")
    return ClipsError(f"No he podido hablar con {who}. Vuelve a probar.")


def _gemini_once(model: str, body: bytes, key: str, timeout: float) -> dict:
    try:
        r = requests.post(f"{API}/v1beta/models/{model}:generateContent", data=body, timeout=timeout,
                          headers={"Content-Type": "application/json", "x-goog-api-key": key})
    except requests.RequestException as e:
        raise network_error(e, "Gemini")
    if r.status_code != 200:
        raise _failure(r.status_code, r.text)
    try:
        cand = r.json()["candidates"][0]
        texts = [p["text"] for p in cand["content"]["parts"] if "text" in p]
        out = json.loads(texts[-1])
        if not isinstance(out, dict):
            raise ValueError
        return out
    except Exception:
        raise ClipsError("Gemini devolvió una respuesta que no entiendo. Vuelve a probar.")


def gemini(parts: list, schema: dict, timeout: float = 240, head_start: float = 40, token: CancelToken = NEVER) -> dict:
    """Llama a Gemini pidiendo JSON con un esquema fijo. Empieza con el mejor modelo; si falla, o si a los
    `head_start` segundos aún no ha contestado, lanza el siguiente a la vez y gana el primero que responda bien.
    Hasta 3 rondas: si todos los modelos están saturados, espera un poco y lo vuelve a intentar."""
    last: Exception = ClipsError("Gemini no responde ahora mismo. Vuelve a probar en un momento.")
    for rnd in range(3):
        try:
            return _gemini_round(parts, schema, timeout, head_start, token)
        except ClipsError as e:
            if e.fatal:
                raise
            last = e
            if rnd < 2:
                if gemini_status:
                    gemini_status("Gemini va saturado; vuelvo a intentarlo en unos segundos…")
                token.sleep(6 + rnd * 8)
    raise last


def _gemini_round(parts, schema, timeout, head_start, token: CancelToken) -> dict:
    key = gemini_key()
    if not key:
        raise missing_key_error()
    body = json.dumps({"contents": [{"parts": parts}],
                       "generationConfig": {"responseMimeType": "application/json", "responseSchema": schema, "temperature": 0.4}}).encode()
    q: queue.Queue = queue.Queue()
    launched = failed = 0
    last: Exception = ClipsError("Gemini no responde ahora mismo. Vuelve a probar en un momento.")

    def worker(i):
        try:
            q.put((i, True, _gemini_once(GEMINI_MODELS[i], body, key, timeout)))
        except Exception as e:
            q.put((i, False, e))

    def launch():
        nonlocal launched
        threading.Thread(target=worker, args=(launched,), daemon=True).start()
        launched += 1
        return time.monotonic() + head_start

    deadline = launch()
    while True:
        token.check()
        try:
            i, ok, val = q.get(timeout=0.25)
        except queue.Empty:
            if launched < len(GEMINI_MODELS) and time.monotonic() >= deadline:
                deadline = launch()
            continue
        if ok:
            return val
        if isinstance(val, ClipsError) and val.fatal:
            raise val
        failed += 1
        last = val
        if launched < len(GEMINI_MODELS):
            deadline = launch()
        elif failed >= launched:
            raise last if isinstance(last, ClipsError) else ClipsError(str(last))


def test_gemini_key(key: str) -> bool:
    """Comprueba la clave sin gastar cuota de generación."""
    try:
        r = requests.get(f"{API}/v1beta/models?pageSize=1", headers={"x-goog-api-key": key}, timeout=20)
        return r.status_code == 200
    except requests.RequestException:
        return False


def gemini_upload(file: Path, mime: str, token: CancelToken = NEVER) -> str:
    """Sube un archivo a la Files API de Gemini y devuelve su URI."""
    key = gemini_key()
    if not key:
        raise missing_key_error()
    size = file.stat().st_size
    try:
        r0 = requests.post(f"{API}/upload/v1beta/files", timeout=60, json={"file": {"display_name": "clips-audio"}}, headers={
            "x-goog-api-key": key, "X-Goog-Upload-Protocol": "resumable", "X-Goog-Upload-Command": "start",
            "X-Goog-Upload-Header-Content-Length": str(size), "X-Goog-Upload-Header-Content-Type": mime})
    except requests.RequestException as e:
        raise network_error(e, "Gemini")
    up = r0.headers.get("x-goog-upload-url")
    if r0.status_code != 200 or not up:
        raise _failure(r0.status_code, r0.text)
    try:
        with open(file, "rb") as fh:
            r1 = requests.post(up, data=fh, timeout=600, headers={"X-Goog-Upload-Command": "upload, finalize", "X-Goog-Upload-Offset": "0"})
        f = r1.json()["file"]
        uri, name = f["uri"], f["name"]
    except requests.RequestException as e:
        raise network_error(e, "Gemini")
    except Exception:
        raise ClipsError("No pude subir el audio a Gemini.")
    # Esperar a que Gemini termine de procesar el archivo.
    for _ in range(60):
        try:
            s = requests.get(f"{API}/v1beta/{name}", headers={"x-goog-api-key": key}, timeout=20).json().get("state")
            if s == "ACTIVE":
                return uri
            if s == "FAILED":
                break
        except Exception:
            pass
        token.sleep(1)
    raise ClipsError("Gemini no pudo procesar el audio del vídeo.")


def transcribe_audio(url: str, workdir: Path, token: CancelToken = NEVER) -> list[Word]:
    """Plan B para vídeos sin subtítulos: bajar el audio y que Gemini lo transcriba con tiempos."""
    run("yt-dlp", ["-f", "ba[abr<=96]/ba/b"] + ytdlp_base() + ["-o", str(workdir / "audio.%(ext)s"), url], token=token)
    src = next(iter(sorted(workdir.glob("audio.*"))), None)
    if not src:
        raise ClipsError("No pude bajar el audio del vídeo.")
    mp3 = workdir / "voz.mp3"
    run("ffmpeg", ["-y", "-i", str(src), "-vn", "-ac", "1", "-ar", "16000", "-c:a", "libmp3lame", "-b:a", "32k", str(mp3)], token=token)
    uri = gemini_upload(mp3, "audio/mpeg", token)
    schema = {"type": "OBJECT", "properties": {"segments": {"type": "ARRAY", "items": {
        "type": "OBJECT", "properties": {"start": {"type": "NUMBER"}, "end": {"type": "NUMBER"}, "text": {"type": "STRING"}},
        "required": ["start", "end", "text"]}}}, "required": ["segments"]}
    r = gemini([{"file_data": {"mime_type": "audio/mpeg", "file_uri": uri}},
                {"text": "Transcribe este audio palabra por palabra, en su idioma original, en frases cortas de 2 a 8 segundos.\n"
                         "\"start\" y \"end\" en segundos exactos desde el inicio del audio. Marca risas, aplausos o música entre corchetes, como [Risas]."}],
               schema, timeout=600, token=token)
    words: list[Word] = []
    for s in r.get("segments") or []:
        a, b, t = num(s.get("start")), num(s.get("end")), s.get("text")
        if a is None or b is None or not isinstance(t, str) or b <= a:
            continue
        words += spread(t, a, b)
    if not words:
        raise ClipsError("No he podido sacar el texto de este vídeo.")
    return sorted(words, key=lambda w: w.start)


# MARK: - Elegir momentos

@dataclass
class Moment:
    start: float
    end: float
    title: str
    reason: str
    caption: str
    score: int
    # Lo que comprobó la revisión (para el registro y el detalle del clip).
    check: str = ""
    # Parte del vídeo a la que pertenece, si se pidió un clip por parte.
    part: int | None = None


@dataclass
class Part:
    start: float
    end: float
    title: str


@dataclass
class ClipPlan:
    """Lo que la persona pide en las notas, ya interpretado. El código hace cumplir número, orden y partes;
    el resto de instrucciones va a cada pasada de Gemini y la verificación final comprueba que se cumplen."""
    count: int | None = None
    chronological: bool = False
    parts: list = field(default_factory=list)
    rules: str = ""
    summary: str = ""

    @property
    def prompt(self) -> str:
        s = ""
        if self.rules:
            s += f"INSTRUCCIONES DE LA PERSONA (mandan sobre los criterios generales, salvo empezar y acabar en frases completas y no inventar nada): {self.rules}\n"
        if self.parts:
            s += "El vídeo se divide en estas partes y se quiere UN clip de cada una, que trate de lo que pasa en esa parte y quede entero dentro de ella:\n"
            s += "\n".join(f"  Parte {i}: {p.start:.0f}–{p.end:.0f} s · {p.title}" for i, p in enumerate(self.parts)) + "\n"
        return s

    def inside(self, m: Moment, p: int) -> float:
        """Cuánto del clip cae dentro de la parte `p` (0–1)."""
        if not (0 <= p < len(self.parts)) or m.end <= m.start:
            return 0
        return max(0.0, min(m.end, self.parts[p].end) - max(m.start, self.parts[p].start)) / (m.end - m.start)

    def part_of(self, m: Moment) -> int | None:
        """La parte que contiene al menos el 80 % del clip."""
        return next((i for i in range(len(self.parts)) if self.inside(m, i) >= 0.8), None)


def num(v) -> float | None:
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        try:
            return float(v)
        except ValueError:
            return None
    return None


def strip_punct(s: str) -> str:
    a, b = 0, len(s)
    while a < b and unicodedata.category(s[a]).startswith("P"):
        a += 1
    while b > a and unicodedata.category(s[b - 1]).startswith("P"):
        b -= 1
    return s[a:b]


def clean_title(s) -> str:
    return (s if isinstance(s, str) else "").strip("\"“” ")


def plan_from_notes(notes: str, info: VideoInfo, words: list[Word], min_d: int, token: CancelToken = NEVER) -> ClipPlan:
    """Interpreta las notas ("10 en orden cronológico", "uno de cada parte"…) en un plan concreto."""
    chapters = "; ".join(f"{s:.0f} s: {t}" for s, t in info.chapters)
    prompt = f"""Una persona va a sacar clips cortos de este vídeo y ha dejado estas anotaciones:
«{notes}»

Tradúcelas a un plan:
- "count": número de clips que pide expresamente (0 si no dice ninguno).
- "order": "chronological" si quiere los clips en el orden en que pasan en el vídeo (también si habla de "en orden", "por orden", "cronológico" o de seguir la historia); si no, "best".
- "one_per_part": true si quiere un clip de cada parte, bloque, sección, capítulo, punto o tema del vídeo.
- "parts": solo si one_per_part es true. Las partes REALES del vídeo, en orden, sin solaparse y cubriendo de principio a fin lo que interesa. Si dice cuántas partes hay ("está estructurado en 5"), devuelve exactamente esas, buscando dónde cambia de verdad de tema en la transcripción. Usa los capítulos si existen y encajan. Cada parte: "start" y "end" en segundos (tomados de las marcas [segundo]) y un "title" corto que diga de qué trata. Ninguna parte de menos de {min_d} s.
- "rules": cualquier OTRA instrucción para elegir o recortar los clips (de qué temas, qué evitar, quién debe salir…), escrita en claro y en español. No repitas aquí el número, el orden ni lo de una por parte: eso ya va en los otros campos. Vacío si no hay más.
- "summary": en una frase en español, qué has entendido (por ejemplo: "10 clips en orden cronológico" o "5 clips, uno de cada parte: …").
No inventes peticiones que no estén en las anotaciones.

Vídeo: "{info.title}", {int(info.duration)} segundos.
{f"Capítulos: {chapters}" + chr(10) if chapters else ""}
TRANSCRIPCIÓN:
{transcript_lines(words)}"""
    part = {"type": "OBJECT", "properties": {"start": {"type": "NUMBER"}, "end": {"type": "NUMBER"}, "title": {"type": "STRING"}},
            "required": ["start", "end", "title"]}
    schema = {"type": "OBJECT", "properties": {
        "count": {"type": "INTEGER"}, "order": {"type": "STRING", "enum": ["best", "chronological"]},
        "one_per_part": {"type": "BOOLEAN"}, "parts": {"type": "ARRAY", "items": part},
        "rules": {"type": "STRING"}, "summary": {"type": "STRING"}},
        "required": ["count", "order", "one_per_part", "parts", "rules", "summary"]}
    r = gemini([{"text": prompt}], schema, token=token)
    plan = ClipPlan()
    c = num(r.get("count"))
    if c is not None and int(c) > 0:
        plan.count = min(int(c), 20)
    plan.chronological = r.get("order") == "chronological"
    plan.rules = (r.get("rules") or "").strip() if isinstance(r.get("rules"), str) else ""
    plan.summary = (r.get("summary") or "").strip() if isinstance(r.get("summary"), str) else ""
    if r.get("one_per_part") is True:
        # Partes en orden, dentro del vídeo y sin solaparse; las demasiado cortas se unen a la anterior.
        dur = info.duration if info.duration > 0 else (words[-1].end if words else 0)
        raw = []
        for d in r.get("parts") or []:
            a, b = num(d.get("start")), num(d.get("end"))
            if a is None or b is None or b <= a:
                continue
            raw.append(Part(max(0.0, a), min(dur, b), d.get("title") if isinstance(d.get("title"), str) else ""))
        parts: list[Part] = []
        for p in sorted(raw, key=lambda p: p.start):
            if parts:
                p.start = max(p.start, parts[-1].end)
            if p.end - p.start >= min_d:
                parts.append(p)
            elif parts:
                parts[-1].end = max(parts[-1].end, p.end)
        plan.parts = parts
        if parts:
            plan.chronological = True
            plan.count = len(parts)
    return plan


FOCUS = {
    "Automático": "Lo que mejor funcione: tensión, giros, humor, revelaciones o frases potentes.",
    "Tensión": "Prioriza momentos de tensión, conflicto, suspense, discusiones y giros.",
    "Humor": "Prioriza los momentos más graciosos: chistes, reacciones, situaciones absurdas, risas.",
    "Aprendizaje": "Prioriza explicaciones claras, consejos útiles y datos sorprendentes que se entiendan solos.",
    "Emoción": "Prioriza momentos emotivos, inspiradores o personales que conmuevan.",
    "Polémica": "Prioriza opiniones fuertes, afirmaciones polémicas y desacuerdos que generen comentarios.",
}


def pick_candidates(info: VideoInfo, words: list[Word], count: int, min_d: int, max_d: int, focus: str,
                    plan: ClipPlan | None = None, only_parts: list[int] | None = None, token: CancelToken = NEVER) -> list[Moment]:
    """Primera pasada: candidatos (más de los que se piden; la revisión decide cuáles valen).
    Con `only_parts`, solo busca en esas partes del plan (para rellenar las que se quedaron sin clip)."""
    plan = plan or ClipPlan()
    peaks = ", ".join(f"{s:.0f}–{e:.0f} s ({v:.2f})" for s, e, v in sorted(info.heatmap, key=lambda h: -h[2])[:10])
    chapters = "; ".join(f"{s:.0f} s: {t}" for s, t in info.chapters)
    wanted = only_parts if only_parts is not None else list(range(len(plan.parts)))
    ask = count + 5 if not plan.parts else len(wanted) * 3
    per_part = "" if not plan.parts else (
        "\n\nDevuelve 3 candidatos de CADA una de estas partes: " + ", ".join(f"Parte {p}" for p in wanted)
        + ". \"part\" es el número de la parte; el clip entero debe caer dentro de ella y tratar de lo que pasa en ella.")
    prompt = f"""Eres editor jefe de un canal que vive de los clips cortos (TikTok, Reels, Shorts). Tu trabajo: encontrar en este vídeo los momentos que, recortados, la gente vería hasta el final y compartiría.

Vídeo: "{info.title}"{f" de {info.channel}" if info.channel else ""}, {int(info.duration)} segundos.
{f"Capítulos: {chapters}" + chr(10) if chapters else ""}Momentos que más repiten los espectadores (rango e intensidad 0–1; buena pista, no obligatoria): {peaks or "sin datos"}

Qué buscar: {FOCUS.get(focus, FOCUS["Automático"])}
{plan.prompt}
Devuelve {ask} candidatos, del mejor al peor.{per_part} Cada uno:
- Dura entre {min_d} y {max_d} segundos.
- Se entiende solo, sin haber visto el resto del vídeo, y se cuenta COMPLETO en esa duración: un chiste con su remate, una reacción, una opinión contundente, una pregunta con su respuesta, una situación con su desenlace. Una anécdota larga solo si su planteamiento y su final caben.
- Empieza justo donde empieza una frase con gancho (nada de "y entonces", "bueno, pues…" ni frases a medias) y termina cuando la idea se cierra: remate, conclusión o reacción. Nunca a mitad de frase.
- No se solapa con otro candidato.
- "start" y "end": segundos del vídeo, tomados de las marcas [segundo] de la transcripción (puedes usar un punto intermedio de una línea si la frase empieza ahí).
- "first_words": las 4 primeras palabras del clip, copiadas tal cual de la transcripción. "last_words": las 4 últimas, tal cual. Comprueba que la última palabra cierra la frase (si la frase sigue en la línea siguiente, inclúyela hasta el final).
- "title": título corto y potente para el clip, en el idioma del vídeo, sin comillas.
- "reason": por qué funciona, en una frase en español, concreta (qué pasa en ese momento).
- "caption": texto para publicarlo en redes, en el idioma del vídeo, 1–2 frases y 3–5 hashtags.
- "score": de 0 a 100, cuánto potencial viral tiene de verdad. Sé exigente.

TRANSCRIPCIÓN (cada línea empieza con el segundo en que se dice; entre corchetes, sonidos como [Risas] o [Música]):
{transcript_lines(words)}"""
    item = {"type": "OBJECT", "properties": {
        "start": {"type": "NUMBER"}, "end": {"type": "NUMBER"}, "title": {"type": "STRING"},
        "reason": {"type": "STRING"}, "caption": {"type": "STRING"}, "score": {"type": "INTEGER"},
        "first_words": {"type": "STRING"}, "last_words": {"type": "STRING"}, "part": {"type": "INTEGER"}},
        "required": ["start", "end", "first_words", "last_words", "title", "reason", "caption", "score"]}
    r = gemini([{"text": prompt}], {"type": "OBJECT", "properties": {"clips": {"type": "ARRAY", "items": item}}, "required": ["clips"]}, token=token)
    speech = [w for w in words if not w.is_tag]
    out: list[Moment] = []
    for c in r.get("clips") or []:
        s0, e0 = num(c.get("start")), num(c.get("end"))
        if s0 is None or e0 is None or e0 <= s0:
            continue
        s, e = anchor(s0, e0, c.get("first_words") or "", c.get("last_words") or "", speech, info.duration)
        if e - s > max_d + 6:
            e = snap(s, s + max_d, speech, info.duration)[1]
        # Si se ha quedado corto (la IA no siempre respeta la duración), alargar hasta una pausa natural.
        if e - s < min_d * 0.9:
            target = s + min_d + (max_d - min_d) * 0.3
            e = max(e, snap(s, target, speech, info.duration)[1])
        if e - s < min_d * 0.6:
            continue
        if any(s < o.end and e > o.start for o in out):
            continue
        m = Moment(s, e, clean_title(c.get("title")) or "Clip", c.get("reason") or "", c.get("caption") or "",
                   max(0, min(100, int(num(c.get("score")) or 50))))
        if plan.parts:
            # La parte la decide el código por dónde cae el clip, no lo que diga la IA; si cruza de una parte a otra, fuera.
            p = plan.part_of(m)
            if p is None or p not in wanted:
                continue
            m.part = p
        out.append(m)
    out.sort(key=lambda m: -m.score)
    if not out:
        raise ClipsError("No he encontrado momentos que se sostengan solos. Prueba con otra duración o con otro enfoque.")
    return out


def boundary_times(i: int, j: int, words: list[Word], duration: float) -> tuple[float, float]:
    """Tiempos de corte para un clip que va de la palabra `i` a la `j`: justo antes de la primera y justo después de la última."""
    dur = duration if duration > 0 else words[j].end + 1
    prev_end = words[i - 1].end if i > 0 else 0
    next_start = words[j + 1].start if j + 1 < len(words) else dur
    a = min(words[i].start - 0.03, max(prev_end + 0.02, words[i].start - 0.15))
    b = min(words[j].end + 0.45, max(words[j].end - 0.02, next_start - 0.05))
    return max(0.0, a), min(dur, b)


TAILS = {"sí", "si", "no", "vale", "bueno", "ya", "eh", "ok", "venga", "claro", "yes", "yeah", "okay", "right", "so"}


def review_moments(info: VideoInfo, words: list[Word], candidates: list[Moment], count: int, min_d: int, max_d: int,
                   notes: list[str] | None = None, before: float = 45, after: float = 30, plan: ClipPlan | None = None,
                   log=None, token: CancelToken = NEVER) -> list[Moment]:
    """Segunda pasada: un editor exigente revisa cada candidato con su contexto, corrige inicio y final palabra a palabra,
    comprueba que título y texto solo cuentan lo que pasa, y descarta lo que no se sostenga."""
    plan = plan or ClipPlan()
    log = log or (lambda s: None)
    speech = [w for w in words if not w.is_tag]
    if not speech:
        return []

    def idx_start(t):
        return next((k for k, w in enumerate(speech) if w.start >= t - 0.05), 0)

    def idx_end(t):
        return next((k for k in range(len(speech) - 1, -1, -1) if speech[k].end <= t + 0.05), len(speech) - 1)

    blocks, windows = [], []
    for k, c in enumerate(candidates):
        i = idx_start(c.start)
        j = max(i, idx_end(c.end))
        lo, hi = idx_start(speech[i].start - before), idx_end(speech[j].end + after)
        hi = max(lo, hi)
        windows.append((lo, hi))
        lines, cur, line_start = [], [], speech[lo].start
        for n in range(lo, hi + 1):
            if not cur:
                line_start = speech[n].start
            cur.append(f"{n}:{speech[n].text}")
            if len(cur) >= 12:
                lines.append(f"[{fmt(line_start)}] " + " ".join(cur))
                cur = []
        if cur:
            lines.append(f"[{fmt(line_start)}] " + " ".join(cur))
        extra = ""
        if c.part is not None:
            p = plan.parts[c.part]
            extra += f"\nDebe quedarse dentro de la Parte {c.part} ({p.start:.0f}–{p.end:.0f} s · {p.title})."
        if notes:
            extra += f"\nPROBLEMA DETECTADO, corrígelo moviendo inicio y/o final (o descarta si no tiene arreglo): {notes[k]}"
        blocks.append(f"""### Candidato {k}
Propuesta: palabras {i}–{j} ({speech[j].end - speech[i].start:.0f} s). Título propuesto: {c.title}{extra}
Texto con contexto (índice:palabra; puedes elegir cualquier índice de este tramo):
{chr(10).join(lines)}""")
    req = ("9. PETICIÓN: el clip cumple lo que pide la persona; si no, corrígelo o descártalo.\n" + plan.prompt) if plan.prompt else ""
    prompt = f"""Eres el editor más exigente de un equipo de clips cortos (TikTok, Reels, Shorts). Revisa uno a uno estos candidatos del vídeo "{info.title}". Para cada uno, razona en "check" (2–4 frases, en español) y decide.

Comprueba, con el texto exacto:
1. INICIO: la primera palabra empieza una idea que se entiende sin nada de lo anterior (no hace falta explicar el programa, el juego ni quiénes son). Si depende de algo dicho antes ("eso", "él", "entonces", una pregunta que se responde…), mueve "start_word" atrás hasta donde empieza esa idea. Si para entenderlo haría falta demasiado, descártalo.
2. FINAL: la última palabra cierra la idea, el remate o la reacción. Si se corta, mueve "end_word" hasta el cierre. Nunca termines a mitad de frase.
3. UNA SOLA SITUACIÓN: el clip cuenta una única situación de principio a fin (un premio, una anécdota, una discusión, una idea). Si dentro del tramo empieza otra situación distinta (otro premio, otra ronda, otro tema), corta "end_word" justo antes de que empiece. Nunca pegues dos situaciones para alcanzar la duración.
4. DURACIÓN: idealmente entre {min_d} y {max_d} segundos (mira las marcas de tiempo). Si la situación completa dura menos, se acepta hasta {int(min_d * 0.7)} s; si hace falta, añade el planteamiento de antes, nunca otra situación de después.
5. COHERENCIA: "title" y "caption" solo pueden contar lo que de verdad se dice o pasa en ese tramo. Compruébalo frase a frase: si el título dice algo que no ocurre (por ejemplo "les roban" cuando lo que pasa es que lo ganan), corrígelo. Nada inventado ni exagerado. En el idioma del vídeo. "reason": qué pasa y por qué engancha, en una frase en español.
6. COMPLETO: tiene planteamiento y desenlace. Si es una anécdota o historia, el clip incluye cómo empieza y su remate. Si el remate o la respuesta llegan después del final, alarga; si la historia entera no cabe en {int(max_d * 1.3)} s, descártala.
7. CALIDAD: descarta (keep=false) si es relleno, presentación, despedida, publicidad, o si no engancharía a alguien que no conoce el vídeo.
8. "score" 0–100, honesto.
{req}
Devuelve un elemento por candidato, con "start_word" y "end_word" como índices del texto mostrado.

{(chr(10) * 2).join(blocks)}"""
    item = {"type": "OBJECT", "properties": {
        "candidate": {"type": "INTEGER"}, "check": {"type": "STRING"}, "keep": {"type": "BOOLEAN"},
        "start_word": {"type": "INTEGER"}, "end_word": {"type": "INTEGER"}, "title": {"type": "STRING"},
        "caption": {"type": "STRING"}, "reason": {"type": "STRING"}, "score": {"type": "INTEGER"}},
        "required": ["candidate", "check", "keep", "start_word", "end_word", "title", "caption", "reason", "score"]}
    r = gemini([{"text": prompt}], {"type": "OBJECT", "properties": {"clips": {"type": "ARRAY", "items": item}}, "required": ["clips"]}, token=token)
    out: list[Moment] = []
    for c in r.get("clips") or []:
        kn = num(c.get("candidate"))
        if kn is None or not (0 <= int(kn) < len(candidates)):
            continue
        k = int(kn)
        check = c.get("check") if isinstance(c.get("check"), str) else ""
        if c.get("keep") is not True:
            log(f"  descartado {k}: {check}")
            continue
        i, j = num(c.get("start_word")), num(c.get("end_word"))
        lo, hi = windows[k]
        if i is None or j is None or not (lo <= int(i) <= hi) or not (lo <= int(j) <= hi) or int(j) <= int(i):
            log(f"  descartado {k}: índices fuera de rango")
            continue
        i, j = int(i), int(j)
        # No empezar con el final de la frase anterior ("Sí.", "Vale,", "Bueno,"…).
        for _ in range(2):
            if i + 1 >= j:
                break
            w = speech[i].text
            if strip_punct(w.lower()) in TAILS and w and w[-1] in ".,!?…":
                i += 1
            else:
                break
        sb = sentence_bounds(i, j, speech, max_d * 1.3)
        if not sb:
            log(f"  descartado {k}: no se puede cerrar en frases completas sin pasarse de duración")
            continue
        s, e = boundary_times(sb[0], sb[1], speech, info.duration)
        if not (e - s >= min_d * 0.7 and e - s <= max_d * 1.3):
            log(f"  descartado {k}: dura {e - s:.0f} s")
            continue
        title = clean_title(c.get("title"))
        cand = candidates[k]
        m = Moment(s, e, title or cand.title, c.get("reason") if isinstance(c.get("reason"), str) else cand.reason,
                   c.get("caption") if isinstance(c.get("caption"), str) else cand.caption,
                   max(0, min(100, int(num(c.get("score")) or 50))), check, cand.part)
        if m.part is not None and plan.inside(m, m.part) < 0.8:
            log(f"  descartado {k}: al ajustarlo se sale de la parte {m.part}")
            continue
        out.append(m)
        log(f"  aprobado {k} ({int(num(c.get('score')) or 0)}): {check}")
    # Sin solapes; se quedan los de más puntuación. Se devuelven todos los aprobados (no solo `count`):
    # si la verificación tumba alguno, quedan reservas.
    final: list[Moment] = []
    for m in sorted(out, key=lambda m: -m.score):
        if not any(m.start < o.end and m.end > o.start for o in final):
            final.append(m)
    return final


def sentence_bounds(i0: int, j0: int, words: list[Word], max_span: float):
    """Ajusta inicio y final a frases completas (con puntuación) o a pausas de la voz (sin ella).
    Devuelve None si para que queden frases completas el clip se pasaría de `max_span` segundos."""
    punctuated = sum(1 for w in words if w.text and w.text[-1] in ".?!,") * 25 > len(words)

    def ends(k):
        if k + 1 >= len(words):
            return True
        if punctuated:
            return bool(words[k].text) and words[k].text[-1] in ".?!…\"”»"
        return words[k + 1].start - words[k].end >= 0.45

    def starts(k):
        return k == 0 or ends(k - 1) or (punctuated and bool(words[k].text) and words[k].text[0] in "¿¡\"“«")

    i, j = i0, j0
    if not starts(i):
        # Atrás hasta el principio de la frase (máx. 15 s); si no aparece, no se puede asegurar.
        k = next((k for k in range(i - 1, -1, -1) if words[i].start - words[k].start <= 15 and starts(k)), None)
        if k is None:
            return None
        i = k
    if not ends(j):
        k = None
        for n in range(j + 1, len(words)):
            if words[n].end - words[j].end > 12:
                break
            if ends(n):
                k = n
                break
        if k is None:
            return None
        j = k
    return (i, j) if words[j].end - words[i].start <= max_span else None


def verify_moments(moments: list[Moment], words: list[Word], min_d: int, plan: ClipPlan | None = None, log=None,
                   token: CancelToken = NEVER):
    """Tercera pasada: verificación final de los clips ya decididos, con su texto exacto.
    Confirma que es una sola situación y que título y texto son ciertos; corrige el título o descarta."""
    plan = plan or ClipPlan()
    log = log or (lambda s: None)
    if not moments:
        return [], []
    speech = [w for w in words if not w.is_tag]
    blocks = []
    for k, m in enumerate(moments):
        text = " ".join(w.text for w in speech if w.start >= m.start - 0.05 and w.end <= m.end + 0.05)
        before = " ".join(w.text for w in speech if w.start >= m.start - 20 and w.end < m.start)
        after = " ".join(w.text for w in speech if m.end < w.start <= m.end + 20)
        part = f" · de la Parte {m.part}: {plan.parts[m.part].title}" if m.part is not None else ""
        blocks.append(f"""### Clip {k} ({int(m.end - m.start)} s){part}
Título: {m.title}
Texto para redes: {m.caption}
(Justo antes, NO entra en el clip): …{before}
LO QUE ENTRA EN EL CLIP: {text}
(Justo después, NO entra en el clip): {after}…""")
    req_ok = "true (no hay instrucciones de la persona)." if not plan.prompt else \
        "¿cumple lo que pide la persona y, si es de una parte, trata de esa parte? (true/false)\n" + plan.prompt
    prompt = f"""Verificación final antes de publicar. Para cada clip, con el texto exacto de lo que se dice:
- "single": ¿cuenta UNA sola situación (aunque haya varias reacciones a ella), sin pegar al final otra escena distinta? (true/false)
- "starts_clean": ¿la primera frase empieza entera y se entiende sin lo de "justo antes"? Es false SOLO si empieza a mitad de frase o si depende de algo dicho justo antes para entenderse ("y por eso…", "el tío dijo…" sin saber qué tío, la respuesta a una pregunta que quedó fuera). NO exijas que se explique el programa, el juego, el formato ni quiénes son: en redes eso se entiende solo.
- "ends_complete": ¿incluye el desenlace o remate? Es false SOLO si la respuesta, la gracia o el final de lo que se cuenta está en "justo después".
- "title_ok": ¿el título describe con verdad lo que pasa? Si no, escribe en "title" uno correcto, corto y con gancho, en el idioma del vídeo; si está bien, repítelo.
- "caption": el texto para redes, corregido si dice algo que no pasa (1–2 frases y 3–5 hashtags, idioma del vídeo).
- "request_ok": {req_ok}
- "problem": en español, qué falla (vacío si nada).
Sé exigente con lo que de verdad confundiría a alguien que lo ve sin contexto, pero no con lo que es normal en un clip corto.

{(chr(10) * 2).join(blocks)}"""
    item = {"type": "OBJECT", "properties": {
        "clip": {"type": "INTEGER"}, "single": {"type": "BOOLEAN"}, "starts_clean": {"type": "BOOLEAN"},
        "ends_complete": {"type": "BOOLEAN"}, "title_ok": {"type": "BOOLEAN"},
        "title": {"type": "STRING"}, "caption": {"type": "STRING"}, "problem": {"type": "STRING"}, "request_ok": {"type": "BOOLEAN"}},
        "required": ["clip", "single", "starts_clean", "ends_complete", "title_ok", "title", "caption", "problem", "request_ok"]}
    r = gemini([{"text": prompt}], {"type": "OBJECT", "properties": {"clips": {"type": "ARRAY", "items": item}}, "required": ["clips"]}, token=token)
    out, failed, seen = [], [], set()
    for c in r.get("clips") or []:
        kn = num(c.get("clip"))
        if kn is None or not (0 <= int(kn) < len(moments)) or int(kn) in seen:
            continue
        k = int(kn)
        seen.add(k)
        m = Moment(**moments[k].__dict__)
        problem = c.get("problem") if isinstance(c.get("problem"), str) else ""
        if not (c.get("single") is True and c.get("starts_clean") is True and c.get("ends_complete") is True
                and (not plan.prompt or c.get("request_ok") is True)):
            log(f"  verificación: falla «{m.title}»: {problem}")
            failed.append((m, problem or "Empieza o acaba a medias."))
            continue
        t = clean_title(c.get("title"))
        if c.get("title_ok") is not True and t:
            log(f"  verificación: título «{m.title}» → «{t}»")
            m.title = t
        if isinstance(c.get("caption"), str) and c["caption"]:
            m.caption = c["caption"]
        out.append(m)
    return sorted(out, key=lambda m: -m.score), failed


WEAK = {"a", "al", "de", "del", "que", "para", "por", "la", "el", "los", "las", "lo", "un", "una", "unos", "unas",
        "y", "e", "o", "u", "ni", "con", "sin", "en", "mi", "tu", "su", "mis", "tus", "sus", "se", "me", "te", "nos", "le", "les",
        "pero", "porque", "como", "si", "cuando", "muy", "más", "the", "an", "of", "to", "and", "or", "in", "on", "for", "with",
        "my", "your", "his", "her", "our", "their", "but", "if", "so"}


def group_lines(ws: list[Word], max_words: int, max_chars: int) -> list[list[Word]]:
    """Agrupa palabras en líneas de subtítulo, siempre con el mismo criterio:
    corta en finales de frase, comas y pausas; nunca deja una línea acabada en "a", "de", "que"…;
    no separa un número de lo que sigue ni dos palabras con mayúscula seguidas ("Apple Watch")."""
    def bare(w):
        return strip_punct(w.text.lower())

    def capital(w):
        t = w.text.lstrip("¿¡\"“«")
        return bool(t) and t[0].isupper()

    lines, cur = [], []
    for k, w in enumerate(ws):
        cur.append(w)
        nxt = ws[k + 1] if k + 1 < len(ws) else None
        length = sum(len(x.text) for x in cur) + len(cur) - 1
        sentence_end = bool(w.text) and w.text[-1] in ".?!…"
        comma = bool(w.text) and w.text[-1] in ",;:"
        gap = (nxt.start - w.end) if nxt else 1
        if nxt is None:
            break
        cut = sentence_end or gap > 0.45 or len(cur) >= max_words or (comma and len(cur) >= 2) or length + 1 + len(nxt.text) > max_chars
        if cut and not sentence_end and not comma and gap <= 0.45:
            # Mejor alargar un poco la línea que dejarla colgando o partir un nombre o una cifra.
            joined = bare(w) in WEAK or (bool(nxt.text) and nxt.text[0].isdigit()) or (len(cur) > 1 and capital(w) and capital(nxt))
            if joined and len(cur) <= max_words and length + 1 + len(nxt.text) <= max_chars + 6:
                cut = False
        if cut:
            lines.append(cur)
            cur = []
    if cur:
        lines.append(cur)
    # Si aun así alguna línea acaba en palabra débil, esa palabra pasa a la siguiente.
    k = 0
    while k + 1 < len(lines):
        last = lines[k][-1] if lines[k] else None
        if len(lines[k]) > 1 and last and bare(last) in WEAK and not (last.text and last.text[-1] in ",.?!"):
            lines[k + 1].insert(0, lines[k].pop())
            continue
        k += 1
    return [l for l in lines if l]


def subtitle_script(words: list[Word], vertical: bool, title: str, token: CancelToken = NEVER):
    """Subtítulos coherentes: Gemini corrige el texto palabra a palabra (lo mal oído, mayúsculas, tildes, signos, muletillas)
    y el código agrupa las líneas. Cada palabra conserva su tiempo. Devuelve None si la respuesta no encaja."""
    ws = [w for w in words if not w.is_tag]
    if len(ws) < 3:
        return None
    max_w, max_c = (3, 18) if vertical else (5, 32)
    listing = " ".join(f"{i}:{w.text}" for i, w in enumerate(ws))
    prompt = f"""Estos son los subtítulos automáticos de un clip ("{title}"), palabra a palabra con su índice. Corrígelos para mostrarlos en pantalla.
Reglas:
- Escribe exactamente lo que se dice, en el mismo idioma. No cambies palabras por sinónimos ni por la versión "oficial" (si dicen "Play", es "Play", no "PS5"). No inventes ni cambies el sentido.
- Corrige: palabras mal transcritas (por el contexto: nombres, marcas, números), mayúsculas (inicio de frase y nombres propios) y tildes.
- Si una palabra no existe o no tiene sentido ahí, es un error del reconocimiento de voz: escribe lo que se dice de verdad, aunque sean dos palabras en el mismo "text" ("Robjet" → "Roba objeto"). Si no estás seguro, déjala como está.
- Puntuación: punto al final de cada frase, coma donde haya pausa natural, signos de pregunta solo en preguntas de verdad (en español con ¿ al principio de la pregunta) y de exclamación solo en exclamaciones claras (con ¡).
- Números con cifras cuando sean cantidades o nombres ("cinco" → "5", "Play 5").
- Quita las muletillas sin significado (eh, em, mmm…) omitiendo su índice.
- Devuelve TODAS las demás palabras, una por elemento, en el mismo orden: {{i, text}}.

{listing}"""
    schema = {"type": "OBJECT", "properties": {"words": {"type": "ARRAY", "items": {
        "type": "OBJECT", "properties": {"i": {"type": "INTEGER"}, "text": {"type": "STRING"}}, "required": ["i", "text"]}}},
        "required": ["words"]}
    # Dos intentos: con Gemini saturado a veces llega tarde o incompleto.
    for _ in range(2):
        try:
            r = gemini([{"text": prompt}], schema, timeout=240, token=token)
        except Cancelled:
            return None
        except Exception:
            continue
        items = r.get("words")
        if not isinstance(items, list):
            continue
        out, last = [], -1
        for w in items:
            # Una palabra mal indicada se descarta sola; no se tira todo el guion.
            i = num(w.get("i")) if isinstance(w, dict) else None
            t = w.get("text").strip() if isinstance(w, dict) and isinstance(w.get("text"), str) else ""
            if i is None or not (last < int(i) < len(ws)) or not t:
                continue
            i = int(i)
            q = next((n for n, ch in enumerate(t) if ch in "¿¡"), None)
            if q:
                t = t[q:]
            out.append(Word(ws[i].start, ws[i].end, t))
            last = i
        # Si se ha dejado demasiadas palabras, no es fiable.
        if len(out) >= len(ws) * 0.75:
            return group_lines(out, max_w, max_c)
    return None


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s.lower())
    return "".join(ch for ch in s if not unicodedata.combining(ch) and ch.isalnum())


def anchor(s: float, e: float, first: str, last: str, words: list[Word], duration: float) -> tuple[float, float]:
    """Busca en la transcripción las palabras exactas con las que empieza y acaba el clip
    (los subtítulos automáticos no traen puntos, así que el texto es la referencia más fiable)."""
    toks = [norm(w.text) for w in words]

    def find(phrase: str, near: float, at_end: bool, after: int = -1):
        q = [x for x in (norm(p) for p in phrase.split(" ")) if x]
        if len(q) < 2:
            return None
        best = None
        for i in range(after + 1, len(toks)):
            si = i - len(q) + 1 if at_end else i
            if si < 0 or si + len(q) > len(toks):
                continue
            hits = sum(1 for n in range(len(q)) if toks[si + n] == q[n])
            if hits < min(3, len(q)):
                continue
            at = words[i].end if at_end else words[i].start
            if abs(at - near) > 25:
                continue
            score = hits * 10 - abs(at - near)
            if best is None or score > best[1]:
                best = (i, score)
        return best[0] if best else None

    i = find(first, s, False)
    j = find(last, e, True, i) if i is not None else None
    if i is None or j is None or j <= i:
        return snap(s, e, words, duration)
    # Si el texto trae puntuación, terminar de cuadrar con la frase: empezar donde empieza
    # y acabar donde acaba (como mucho unas palabras más allá).
    punctuated = sum(1 for w in words if w.text and w.text[-1] in ".?!,") * 25 > len(words)
    if punctuated:
        def ends_sentence(k):
            return bool(words[k].text) and words[k].text[-1] in ".?!…\"”»"

        def starts_sentence(k):
            return k == 0 or ends_sentence(k - 1) or (bool(words[k].text) and words[k].text[0] in "\"“«¿¡(")

        if not starts_sentence(i):
            k = next((k for k in range(i - 1, max(0, i - 3) - 1, -1) if starts_sentence(k)), None)
            if k is not None:
                i = k
        if not ends_sentence(j):
            k = next((k for k in range(j + 1, min(len(words), j + 5)) if ends_sentence(k)), None)
            if k is not None:
                j = k
    dur = duration if duration > 0 else words[j].end + 1
    prev_end = words[i - 1].end if i > 0 else 0
    next_start = words[j + 1].start if j + 1 < len(words) else dur
    # Empezar justo antes de la primera palabra, nunca dentro de ella.
    a = min(words[i].start - 0.03, max(prev_end + 0.02, words[i].start - 0.15))
    # Cortar antes de que empiece la palabra siguiente; si hay pausa, dejar un poco de aire.
    b = min(words[j].end + 0.45, max(words[j].end - 0.02, next_start - 0.05))
    return max(0.0, a), min(dur, b)


def snap(s: float, e: float, words: list[Word], duration: float) -> tuple[float, float]:
    """Plan B si no aparecen las palabras: ajusta a la palabra más cercana, prefiriendo pausas naturales."""
    dur = duration if duration > 0 else e + 1
    if not words:
        return max(0.0, s), min(dur, e)
    best_s = None
    for i, w in enumerate(words):
        if abs(w.start - s) <= 2.5:
            gap = 3 if i == 0 else w.start - words[i - 1].end
            score = min(gap, 1.0) - abs(w.start - s) * 0.8
            if best_s is None or score > best_s[1]:
                best_s = (i, score)
    floor = words[best_s[0]].start if best_s else s
    best_e = None
    for i, w in enumerate(words):
        if abs(w.end - e) <= 2.5 and w.end > floor:
            gap = 3 if i == len(words) - 1 else words[i + 1].start - w.end
            score = min(gap, 1.0) - abs(w.end - e) * 0.8
            if best_e is None or score > best_e[1]:
                best_e = (i, score)
    a, b = s, e
    if best_s:
        i = best_s[0]
        prev_end = words[i - 1].end if i > 0 else 0
        a = min(words[i].start - 0.03, max(prev_end + 0.02, words[i].start - 0.15))
    if best_e:
        i = best_e[0]
        next_start = words[i + 1].start if i + 1 < len(words) else dur
        b = min(words[i].end + 0.4, max(words[i].end - 0.02, next_start - 0.05))
    return max(0.0, a), min(dur, b)
