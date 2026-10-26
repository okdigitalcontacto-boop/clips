# Clips para Windows · © 2026 OK Digital. Todos los derechos reservados.
"""Descarga por trozos, cámara que sigue a la persona, subtítulos, título, música y exportación.
El montaje es fotograma a fotograma: ffmpeg decodifica, Python compone (recorte, texto) y ffmpeg codifica."""
from __future__ import annotations

import json
import math
import re
import threading
import unicodedata
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

from .core import Word, group_lines
from .music import SR, compose_music, decode_audio
from .util import ClipsError, CancelToken, NEVER, kill_tree, popen, procs, resource_dir, run, run_capture, ytdlp_base

cv2.setNumThreads(2)

# Margen que se baja antes y después del clip, para poder retocar inicio y final sin volver a descargar.
SECTION_MARGIN = 6.0


@dataclass
class VideoSection:
    file: Path
    start: float
    end: float


@dataclass
class RenderOptions:
    vertical: bool = True
    subtitles: bool = True
    music: bool = True
    mood: str = "Calma"
    hook: bool = True


# MARK: - Descargar solo el trozo que hace falta

def download_section(url: str, a: float, b: float, workdir: Path, name: str, max_res: int = 1080,
                     on_progress=None, token: CancelToken = NEVER) -> VideoSection:
    """`max_res`: 1440 para vertical (el recorte 9:16 gana un 33 % de detalle), 1080 para horizontal."""
    start = max(0.0, a)
    length = b - start
    out = workdir / f"{name}.mp4"
    out.unlink(missing_ok=True)

    def line(s: str):
        # ffmpeg informa "time=00:00:12.34"; lo convertimos en porcentaje del trozo.
        m = re.search(r"time=(\d+):(\d+):(\d+(?:\.\d+)?)", s)
        if m and length > 0 and on_progress:
            on_progress(min(1.0, (int(m[1]) * 3600 + int(m[2]) * 60 + float(m[3])) / length))

    run("yt-dlp", ["-f", "bv*+ba/b", "-S", f"res:{max_res},vcodec:h264,acodec:m4a",
                   "--download-sections", f"*{start:.2f}-{b:.2f}", "--merge-output-format", "mp4",
                   "--newline", "--no-part"] + ytdlp_base() + ["-o", str(out), url], on_line=line, token=token)
    if not out.exists():
        raise ClipsError("No se pudo descargar este trozo del vídeo.")
    return VideoSection(out, start, b)


@dataclass
class Probe:
    width: int
    height: int
    fps: float
    duration: float
    audio_end: float | None


def probe(file: Path, token: CancelToken = NEVER) -> Probe:
    d = json.loads(run("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", str(file)], token=token))
    v = next((s for s in d.get("streams", []) if s.get("codec_type") == "video"), None)
    if not v:
        raise ClipsError("El trozo descargado no tiene imagen.")
    w, h = int(v["width"]), int(v["height"])
    rot = 0
    for sd in v.get("side_data_list") or []:
        if "rotation" in sd:
            rot = int(sd["rotation"])
    if abs(rot) in (90, 270):
        w, h = h, w

    def rate(s):
        try:
            n, m = s.split("/")
            return float(n) / float(m) if float(m) else 0
        except Exception:
            return 0

    fps = rate(v.get("avg_frame_rate", "0/1")) or rate(v.get("r_frame_rate", "0/1")) or 30
    dur = float(d.get("format", {}).get("duration") or v.get("duration") or 0)
    a = next((s for s in d.get("streams", []) if s.get("codec_type") == "audio"), None)
    audio_end = None
    if a:
        audio_end = float(a.get("start_time") or 0) + float(a.get("duration") or dur)
    return Probe(w, h, fps, dur, audio_end)


class FrameReader:
    """Fotogramas en bruto de ffmpeg (RGB o BGR) leídos por una tubería."""

    def __init__(self, file: Path, start: float, length: float, vf: str, width: int, height: int, pix: str = "rgb24",
                 token: CancelToken = NEVER):
        self.size = width * height * (1 if pix == "gray" else 3)
        self.shape = (height, width) if pix == "gray" else (height, width, 3)
        self.p = popen("ffmpeg", ["-v", "error", "-ss", f"{max(0, start):.3f}", "-i", str(file), "-t", f"{length:.3f}",
                                  "-vf", vf, "-f", "rawvideo", "-pix_fmt", pix, "-"])
        self.token = token
        self.err = []
        threading.Thread(target=lambda: self.err.append(self.p.stderr.read()), daemon=True).start()

    def __iter__(self):
        try:
            while True:
                if self.token.cancelled:
                    break
                buf = self.p.stdout.read(self.size)
                if not buf or len(buf) < self.size:
                    break
                yield np.frombuffer(buf, np.uint8).reshape(self.shape)
        finally:
            self.close()

    def close(self):
        kill_tree(self.p)
        procs.remove(self.p)
        try:
            self.p.stdout.close()
        except Exception:
            pass


# MARK: - Análisis del plano: a quién seguir y dónde hay cambios de plano

@dataclass
class ShotSample:
    t: float
    target: tuple | None  # (x, y) en 0–1, origen arriba a la izquierda
    cut: bool
    crowd: bool = False


_face_lock = threading.Lock()


def _face_detector():
    return cv2.FaceDetectorYN.create(str(resource_dir() / "assets/models/face_detection_yunet_2023mar.onnx"), "", (320, 320), 0.6, 0.3, 50)


def detect_cuts(file: Path, a: float, b: float, token: CancelToken = NEVER) -> list[float]:
    """Cambios de plano: miniaturas en gris de 32×18 comparadas 16 veces por segundo (≈ 6 centésimas)."""
    cuts, prev, k = [], None, 0
    for f in FrameReader(file, a, b - a, "fps=16,scale=32:18:flags=area", 32, 18, "gray", token):
        cur = f.astype(np.int16)
        if prev is not None and float(np.abs(cur - prev).mean()) > 38:
            cuts.append(k / 16)
        prev, k = cur, k + 1
    return cuts


def analyze_shots(file: Path, a: float, b: float, view_width: float, token: CancelToken = NEVER) -> list[ShotSample]:
    """Decide a quién seguir en cada momento: caras (si caben juntas, el grupo; si no, quien habla)."""
    pr = probe(file, token)
    cuts = detect_cuts(file, a, b, token)
    sw = 512
    sh = max(2, int(round(pr.height * sw / pr.width / 2)) * 2)
    det = _face_detector()
    det.setInputSize((sw, sh))
    step = 0.25
    samples: list[ShotSample] = []
    tracks: list[dict] = []  # center, mouth [(t, movimiento)], last, patch
    speaker, speaker_since = None, 0.0
    prev_t = -1.0
    ci = 0
    for k, img in enumerate(FrameReader(file, a, b - a, f"fps=4,scale={sw}:{sh}", sw, sh, "bgr24", token)):
        t = k * step
        cut_at = None
        while ci < len(cuts) and cuts[ci] <= t:
            if cuts[ci] > prev_t:
                cut_at = cuts[ci]
            ci += 1
        if cut_at is not None:
            tracks, speaker = [], None
        prev_t = t
        with _face_lock:
            _, faces = det.detect(np.ascontiguousarray(img))
        faces = [] if faces is None else [f for f in faces if f[2] / sw > 0.025]
        target, crowd = None, False
        if faces:
            gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
            ids = []
            for f in faces:
                x, y, w, h = (float(v) for v in f[:4])
                c = ((x + w / 2) / sw, (y + h / 2) / sh)
                # Cuánto se mueve la boca: diferencia de la zona de la boca con el fotograma anterior.
                rmx, rmy, lmx, lmy = (float(v) for v in f[10:14])
                mw = max(6.0, abs(lmx - rmx) * 1.4)
                cx, cy = (rmx + lmx) / 2, (rmy + lmy) / 2
                x0, y0 = int(max(0, cx - mw / 2)), int(max(0, cy - mw * 0.35))
                x1, y1 = int(min(sw, cx + mw / 2)), int(min(sh, cy + mw * 0.35))
                patch = cv2.resize(gray[y0:y1, x0:x1], (16, 8), interpolation=cv2.INTER_AREA).astype(np.int16) if x1 > x0 + 2 and y1 > y0 + 2 else None
                best = min(range(len(tracks)), key=lambda i: math.dist(tracks[i]["center"], c), default=None)
                if best is not None and math.dist(tracks[best]["center"], c) < 0.15:
                    tr = tracks[best]
                    move = float(np.abs(patch - tr["patch"]).mean()) if patch is not None and tr["patch"] is not None else 0.0
                    tr.update(center=c, last=t, patch=patch)
                    tr["mouth"].append((t, move))
                    ids.append(best)
                else:
                    tracks.append({"center": c, "mouth": [], "last": t, "patch": patch})
                    ids.append(len(tracks) - 1)
            boxes = [(f[0] / sw, f[1] / sh, (f[0] + f[2]) / sw, (f[1] + f[3]) / sh) for f in faces]
            ux0, uy0 = min(b_[0] for b_ in boxes), min(b_[1] for b_ in boxes)
            ux1, uy1 = max(b_[2] for b_ in boxes), max(b_[3] for b_ in boxes)
            uw = ux1 - ux0
            crowd = len(faces) >= 3 and uw > view_width * 0.85
            if len(faces) == 1 or uw <= view_width * 0.85:
                # El grupo entero; en altura, la cara que está más arriba.
                target = ((ux0 + ux1) / 2, float(min((b_[1] + b_[3]) / 2 for b_ in boxes)))
            else:
                # Quien habla: la boca que más se mueve en el último segundo y medio.
                def talk(i):
                    v = [m for (tt, m) in tracks[i]["mouth"] if tt > t - 1.6]
                    return sum(v) / len(v) if v else 0.0
                best = max(ids, key=talk)
                if speaker is not None and speaker in ids and (t - speaker_since < 1.0 or talk(best) < talk(speaker) * 1.35 + 0.5):
                    target = tracks[speaker]["center"]
                else:
                    if speaker != best:
                        speaker_since = t
                    speaker = best
                    target = tracks[best]["center"]
        samples.append(ShotSample(cut_at if cut_at is not None else t, target, cut_at is not None, crowd))
    return samples


@dataclass
class CameraPlan:
    x: np.ndarray
    y: np.ndarray
    z: np.ndarray
    fit: bool
    fps: float = 30.0

    def at(self, t: float):
        i = min(len(self.x) - 1, max(0, int(t * self.fps)))
        return float(self.x[i]), float(self.y[i]), float(self.z[i])


def plan_camera(samples: list[ShotSample], duration: float) -> CameraPlan:
    """Cámara tranquila: un solo modo para todo el clip (seguir a la persona o plano entero), movimiento lento con inercia
    y sin temblar, reencuadre suave en los cambios de plano (salto solo si el sujeto está en otro sitio) y un vaivén
    de zoom muy lento y continuo. Nada de golpes ni saltos de zoom."""
    fps, dt = 30.0, 1 / 30.0
    n = int(duration * fps) + 2
    xs, ys, zs = np.full(n, 0.5), np.full(n, 0.5), np.ones(n)
    srt = sorted(samples, key=lambda s: s.t)
    # Modo único para todo el clip: si casi siempre se ve a alguien (y no es un grupo que no cabe), seguirle.
    seen = sum(1 for s in srt if s.target is not None)
    crowd = sum(1 for s in srt if s.crowd)
    fit = not srt or seen < len(srt) * 0.6 or crowd > len(srt) * 0.4
    tgt = next((s.target for s in srt if s.target is not None), (0.5, 0.5))
    x, y, vx, vy = tgt[0], tgt[1], 0.0, 0.0
    w = 2 * math.pi / 1.3  # respuesta ~1,3 s: lenta, como un operador
    k = 0
    for i in range(n):
        t = i * dt
        cut = False
        while k < len(srt) and srt[k].t <= t:
            if srt[k].target is not None:
                tgt = srt[k].target
            if srt[k].cut:
                cut = True
            k += 1
        tx, ty = tgt
        # En un cambio de plano solo se salta si el sujeto está claramente en otro sitio.
        if i == 0 or (cut and math.hypot(tx - x, ty - y) > 0.15):
            x, y, vx, vy = tx, ty, 0.0, 0.0
        # Zona muerta amplia: si el sujeto se mueve poco, la cámara no se mueve.
        if abs(tx - x) < 0.05 and abs(vx) < 0.02:
            tx = x
        if abs(ty - y) < 0.06 and abs(vy) < 0.02:
            ty = y
        vx += (w * w * (tx - x) - 2 * w * vx) * dt
        x += vx * dt
        vy += (w * w * (ty - y) - 2 * w * vy) * dt
        y += vy * dt
        xs[i], ys[i] = x, y
        # Vaivén de zoom muy lento (1,00 → 1,05 → 1,00 cada ~16 s).
        zs[i] = 1 + 0.025 * (1 - math.cos(2 * math.pi * t / 16))
    return CameraPlan(xs, ys, zs, fit)


# MARK: - Texto: subtítulos y título

def _font(name: str, size: float, weight: int) -> ImageFont.FreeTypeFont:
    f = ImageFont.truetype(str(resource_dir() / "assets/fonts" / name), max(1, int(round(size))))
    try:
        axes = f.get_variation_axes()
        vals = []
        for a in axes:
            nm = a.get("name", b"")
            nm = nm.decode() if isinstance(nm, bytes) else str(nm)
            if "eight" in nm:
                vals.append(weight)
            elif "ptical" in nm:
                vals.append(a["maximum"])
            else:
                vals.append(a["default"])
        f.set_variation_by_axes(vals)
    except Exception:
        pass
    return f


def drawable(s: str) -> str:
    """Quita emojis y símbolos que la fuente no tiene (saldrían como cuadraditos)."""
    return "".join(ch for ch in s if unicodedata.category(ch) not in ("So", "Cs", "Co", "Cn") and ch not in "‍️").strip()


def _shadowed(canvas_size, draw_fn, sigma: float, offset: float, alpha: float) -> Image.Image:
    """Texto blanco con sombra suave debajo."""
    mask = Image.new("L", canvas_size, 0)
    draw_fn(ImageDraw.Draw(mask), 255)
    sh_alpha = mask.filter(ImageFilter.GaussianBlur(max(0.1, sigma))).point(lambda v: int(v * alpha))
    shadow = Image.merge("RGBA", (Image.new("L", canvas_size, 0),) * 3 + (sh_alpha,))
    shadow = shadow.transform(canvas_size, Image.AFFINE, (1, 0, 0, 0, 1, -offset), resample=Image.BILINEAR)
    text = Image.merge("RGBA", (Image.new("L", canvas_size, 255),) * 3 + (mask,))
    return Image.alpha_composite(shadow, text)


@dataclass
class SubChunk:
    start: float
    end: float
    image: np.ndarray  # RGBA premultiplicado no; RGBA normal
    x: int
    y: int
    words: list  # [(desde, (x0, y0, x1, y1))] relativos a la imagen
    radius: float


def clean_word(w: str) -> str:
    """Quita la puntuación suelta del final (".", ",", ";", ":") y deja "?" y "!"."""
    while len(w) > 1 and w[-1] in ".,;:…":
        w = w[:-1]
    return w


def subtitle_chunks(words: list[Word], lines, size: tuple[int, int], vertical: bool, duration: float) -> list[SubChunk]:
    """Subtítulos limpios: letra gruesa en blanco con sombra suave, en una línea; la palabra que se dice va en una pastilla coral."""
    W, H = size
    chunks = lines or group_lines(words, 3 if vertical else 5, 18 if vertical else 32)
    base_size = 86 if vertical else max(46, H * 0.064)
    max_width = W * (0.84 if vertical else 0.78)
    center_y = H * (0.73 if vertical else 0.88)
    out = []
    for ci, chunk in enumerate(chunks):
        texts = [drawable(clean_word(w.text)) or w.text for w in chunk]
        if lines is None and texts and texts[0][:1].islower():
            texts[0] = texts[0][0].upper() + texts[0][1:]
        fs = base_size
        gap_k = 0.42
        font = _font("Inter.ttf", fs, 800)
        full = sum(font.getlength(t) for t in texts) + fs * gap_k * (len(texts) - 1)
        if full > max_width:  # si la línea no cabe, se reduce la letra (nunca dos líneas)
            fs *= max_width / full
            font = _font("Inter.ttf", fs, 800)
        ws = [font.getlength(t) for t in texts]
        gap = fs * gap_k
        line_w = sum(ws) + gap * (len(texts) - 1)
        ascent, descent = font.getmetrics()
        cap_h = -font.getbbox("H", anchor="ls")[1]
        pad = fs * 0.45
        cw, ch = int(math.ceil(line_w + pad * 2)), int(math.ceil(ascent + descent + pad * 2))
        baseline = pad + ascent

        def draw(d, fill):
            dx = pad
            for k, t in enumerate(texts):
                d.text((dx, baseline), t, font=font, fill=fill, anchor="ls")
                dx += ws[k] + gap

        img = _shadowed((cw, ch), draw, sigma=fs * 0.09, offset=fs * 0.05, alpha=0.55)
        # Pastilla de cada palabra: centrada en la altura de las mayúsculas, con margen.
        rects, x = [], pad
        for k in range(len(texts)):
            rects.append((chunk[k].start, (x - fs * 0.2, baseline - cap_h - fs * 0.2, x + ws[k] + fs * 0.2, baseline + fs * 0.2)))
            x += ws[k] + gap
        nxt = chunks[ci + 1][0].start if ci + 1 < len(chunks) else duration
        out.append(SubChunk(chunk[0].start, min(chunk[-1].end + 0.3, nxt), np.array(img), int(round((W - cw) / 2)),
                            int(round(center_y - ch / 2)), rects, fs * 0.22))
    return out


ACCENT = np.array([255, 92, 56], np.float32)  # coral #FF5C36


def _rounded_alpha(h: int, w: int, rect, radius: float) -> np.ndarray:
    """Máscara suavizada (antialias) de un rectángulo redondeado."""
    x0, y0, x1, y1 = rect
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32) + 0.5
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    hx, hy = (x1 - x0) / 2 - radius, (y1 - y0) / 2 - radius
    qx, qy = np.abs(xs - cx) - hx, np.abs(ys - cy) - hy
    d = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - radius
    return np.clip(0.5 - d, 0, 1)


def blend(dst: np.ndarray, rgba: np.ndarray, x: int, y: int, alpha: float = 1.0) -> None:
    """Pega una imagen RGBA sobre el fotograma (recortando por los bordes)."""
    h, w = rgba.shape[:2]
    H, W = dst.shape[:2]
    x0, y0, x1, y1 = max(0, x), max(0, y), min(W, x + w), min(H, y + h)
    if x1 <= x0 or y1 <= y0:
        return
    src = rgba[y0 - y:y1 - y, x0 - x:x1 - x].astype(np.float32)
    a = src[..., 3:4] * (alpha / 255.0)
    roi = dst[y0:y1, x0:x1].astype(np.float32)
    dst[y0:y1, x0:x1] = (src[..., :3] * a + roi * (1 - a)).astype(np.uint8)


def draw_subtitle(frame: np.ndarray, c: SubChunk, t: float) -> None:
    """Pinta un bloque en el instante `t`: entra subiendo y apareciendo (0,16 s) y la pastilla se desliza de palabra en palabra."""
    local = t - c.start
    u = min(1.0, local / 0.16)
    ease = 1 - (1 - u) ** 3
    i = 0
    for k, (start, _) in enumerate(c.words):
        if start <= t:
            i = k
    r = c.words[i][1]
    since = t - c.words[i][0]
    if i > 0 and since < 0.1:
        v = since / 0.1
        e = v * v * (3 - 2 * v)
        p = c.words[i - 1][1]
        r = (p[0] + (r[0] - p[0]) * e, r[1], p[2] + (r[2] - p[2]) * e, r[3])
    h, w = c.image.shape[:2]
    layer = np.zeros((h, w, 4), np.float32)
    m = _rounded_alpha(h, w, r, c.radius) * 0.96
    layer[..., :3] = ACCENT
    layer[..., 3] = m * 255
    txt = c.image.astype(np.float32)
    ta = txt[..., 3:4] / 255
    la = layer[..., 3:4] / 255
    out_a = ta + la * (1 - ta)
    rgb = (txt[..., :3] * ta + layer[..., :3] * la * (1 - ta)) / np.maximum(out_a, 1e-6)
    comp = np.concatenate([rgb, out_a * 255], axis=2)
    blend(frame, comp, c.x, c.y + int(round(14 * (1 - ease))), ease)


def wrap(text: str, font: ImageFont.FreeTypeFont, max_w: float) -> list[str]:
    lines, cur = [], ""
    for word in text.split():
        cand = (cur + " " + word).strip()
        if font.getlength(cand) <= max_w or not cur:
            cur = cand
        else:
            lines.append(cur)
            cur = word
    if cur:
        lines.append(cur)
    return lines


@dataclass
class Hook:
    image: np.ndarray
    cx: float
    cy: float
    start: float = 0.0
    end: float = 3.2


def hook_overlay(title: str, size: tuple[int, int], vertical: bool) -> Hook | None:
    """El título del clip en una tarjeta blanca arriba durante los primeros 3 s."""
    W, H = size
    text = drawable(title[:70])
    if not text:
        return None
    fs = 74 if vertical else max(40, H * 0.058)
    font = _font("Nunito.ttf", fs, 900)
    lines = wrap(text, font, W * (0.74 if vertical else 0.56))
    line_h = fs * 0.92 * 1.18
    ascent, descent = font.getmetrics()
    label_w = max(font.getlength(l) for l in lines)
    label_h = line_h * (len(lines) - 1) + ascent + descent
    pad_x, pad_y, shadow_pad = fs * 0.55, fs * 0.36, fs * 0.6
    cw, ch = label_w + pad_x * 2, label_h + pad_y * 2
    Wc, Hc = int(math.ceil(cw + shadow_pad * 2)), int(math.ceil(ch + shadow_pad * 2))
    card = (shadow_pad, shadow_pad, shadow_pad + cw, shadow_pad + ch)
    # Sombra suave debajo de la tarjeta.
    mask = Image.new("L", (Wc, Hc), 0)
    ImageDraw.Draw(mask).rounded_rectangle(card, radius=fs * 0.42, fill=255)
    sh = mask.filter(ImageFilter.GaussianBlur(fs * 0.35 / 2)).point(lambda v: int(v * 0.35))
    sh = sh.transform((Wc, Hc), Image.AFFINE, (1, 0, 0, 0, 1, -fs * 0.08), resample=Image.BILINEAR)
    img = Image.merge("RGBA", (Image.new("L", (Wc, Hc), 0),) * 3 + (sh,))
    # Tarjeta blanca con bordes suaves (dibujada al doble y reducida).
    big = Image.new("L", (Wc * 2, Hc * 2), 0)
    ImageDraw.Draw(big).rounded_rectangle(tuple(v * 2 for v in card), radius=fs * 0.84, fill=255)
    card_a = big.resize((Wc, Hc), Image.LANCZOS)
    white = Image.merge("RGBA", (Image.new("L", (Wc, Hc), 255),) * 3 + (card_a,))
    img = Image.alpha_composite(img, white)
    d = ImageDraw.Draw(img)
    y = card[1] + pad_y + ascent
    for l in lines:
        d.text((card[0] + cw / 2, y), l, font=font, fill=(18, 18, 18, 255), anchor="ms")
        y += line_h
    center_y = H * (0.21 if vertical else 0.17)
    return Hook(np.array(img), W / 2, center_y)


def draw_hook(frame: np.ndarray, hk: Hook, t: float) -> None:
    local = t - hk.start
    img = hk.image
    if local < 0.22:
        # Entra con un pequeño salto.
        u = local / 0.22
        k = 0.82 + (1.06 - 0.82) * (u / 0.6) if u < 0.6 else 1.06 - 0.06 * ((u - 0.6) / 0.4)
        img = cv2.resize(img, (max(1, int(img.shape[1] * k)), max(1, int(img.shape[0] * k))), interpolation=cv2.INTER_LINEAR)
    a = max(0.0, min(1.0, local / 0.15, (hk.end - t) / 0.4))
    blend(frame, img, int(round(hk.cx - img.shape[1] / 2)), int(round(hk.cy - img.shape[0] / 2)), a)


# MARK: - Montaje final

def _cover_blur(frame: np.ndarray, R: tuple[int, int]) -> np.ndarray:
    """El mismo plano ampliado, difuminado y algo más oscuro, de fondo."""
    Rw, Rh = R
    H, W = frame.shape[:2]
    bs = max(Rw / W, Rh / H) * 1.08 / 8
    small = cv2.resize(frame, (max(2, int(W * bs)), max(2, int(H * bs))), interpolation=cv2.INTER_AREA)
    sw, sh = Rw // 8, Rh // 8
    x0, y0 = max(0, (small.shape[1] - sw) // 2), max(0, (small.shape[0] - sh) // 2)
    small = small[y0:y0 + sh, x0:x0 + sw]
    small = cv2.GaussianBlur(small, (0, 0), 38 / 8)
    f = small.astype(np.float32)
    lum = f @ np.array([0.299, 0.587, 0.114], np.float32)
    f = lum[..., None] + (f - lum[..., None]) * 1.1 - 0.12 * 255
    return cv2.resize(np.clip(f, 0, 255).astype(np.uint8), (Rw, Rh), interpolation=cv2.INTER_LINEAR)


def level_envelope(words: list[Word], start: float, end: float, dur: float, n: int) -> np.ndarray:
    """Volumen de la música en cada muestra: baja cuando se habla y sube un poco en las pausas largas."""
    speech = sorted((w.start - start, w.end - start) for w in words if not w.is_tag and w.end > start and w.start < end)
    # Pausas largas (más de 2,5 s sin hablar): ahí la música puede subir un poco, despacio.
    gaps, last = [], 0.0
    for a, b in speech:
        if a - last > 2.5:
            gaps.append((last + 0.6, a - 0.6))
        last = max(last, b)
    if dur - last > 2.5:
        gaps.append((last + 0.6, dur))
    t = np.arange(n) / SR
    fade = np.minimum(1, t / 1.2) * np.minimum(1, np.maximum(0, dur - t) / 1.5)
    lift = np.zeros(n)
    for a, b in gaps:
        if b > a:
            lift = np.maximum(lift, np.clip(np.minimum((t - a) / 0.8, (b - t) / 0.8), 0, 1))
    # Medido: ~13 dB por debajo de la voz; en pausas largas sube hasta ~9 dB, con rampas de 0,8 s.
    return (fade * (0.20 + 0.11 * lift)).astype(np.float32)


def render_clip(section: VideoSection, start_in: float, end_in: float, words: list[Word], options: RenderOptions,
                hook: str | None, music: Path | None, music_seed: int, script, out: Path, workdir: Path,
                token: CancelToken = NEVER, log=None) -> float:
    """Monta el clip y devuelve su duración real. `script`: líneas de subtítulos ya corregidas (si no, se agrupan solas)."""
    pr = probe(section.file, token)
    src_w, src_h = pr.width, pr.height
    local_start = max(0.0, start_in - section.start)
    local_end = min(pr.duration, end_in - section.start)
    if local_end - local_start <= 0.5:
        raise ClipsError("El trozo descargado es demasiado corto.")

    # Planos y a quién seguir. Si hay un cambio de plano pegado al inicio o al final, cortar ahí
    # (sin perder palabras) para no empezar ni acabar con un fogonazo de otro plano.
    view_width = min(1.0, src_h / src_w * 9 / 16) if options.vertical else 1.0
    shots = analyze_shots(section.file, local_start, local_end, view_width, token)
    token.check()
    spoken = [w for w in words if not w.is_tag]
    first_word = next((w.start for w in spoken if w.end > start_in), start_in)
    last_word = next((w.end for w in reversed(spoken) if w.start < end_in), end_in)
    c = next((s for s in shots if s.cut and 0 < s.t <= 0.4), None)
    if c and section.start + local_start + c.t <= first_word + 0.04:
        ct = c.t
        local_start += ct
        shots = [ShotSample(s.t - ct, s.target, False if s.t == ct else s.cut, s.crowd) for s in shots if s.t >= ct]
    span = local_end - local_start
    c = next((s for s in reversed(shots) if s.cut and span - 0.4 <= s.t < span), None)
    if c and section.start + local_start + c.t >= last_word - 0.04:
        local_end = local_start + c.t
        shots = [s for s in shots if s.t < c.t]
    start, end = section.start + local_start, section.start + local_end
    dur = local_end - local_start

    # Tamaño de salida: vertical 1080×1920; horizontal, el del original hasta 1920 de ancho.
    if options.vertical:
        R = (1080, 1920)
    else:
        k = min(1.0, 1920 / max(src_w, src_h))
        R = (int(round(src_w * k / 2)) * 2, int(round(src_h * k / 2)) * 2)
    Rw, Rh = R
    base_scale = max(Rw / src_w, Rh / src_h)
    plan = plan_camera(shots, dur)
    can_fit = Rh > Rw * 1.2 and src_w > src_h  # vídeo apaisado en salida vertical
    fit = plan.fit and can_fit

    subs: list[SubChunk] = []
    if options.subtitles:
        clip_words = [Word(max(0, w.start - start), min(dur, w.end - start), w.text)
                      for w in words if not w.is_tag and start - 0.1 <= w.start < end - 0.08]
        lines = None
        if script:
            lines = [[Word(max(0, w.start - start), min(dur, w.end - start), w.text) for w in l if start - 0.1 <= w.start < end - 0.08] for l in script]
            lines = [l for l in lines if l] or None
        if clip_words or lines:
            subs = subtitle_chunks(clip_words, lines, R, options.vertical, dur)
    hk = hook_overlay(hook, R, options.vertical) if hook and dur > 5 else None
    if log:
        log(f"  subtítulos: {len(subs)} bloques ({'revisados' if script else 'automáticos'}), cortes: {sum(1 for s in shots if s.cut)}, "
            f"modo: {'plano entero' if fit else 'seguir'}")

    # Audio: voz del trozo + música que baja cuando se habla, medido para dejarlo a -14 LUFS.
    n = int(round(dur * SR))
    voice = np.zeros((n, 2), np.float32)
    if pr.audio_end is not None and pr.audio_end - local_start > 0.05:
        v = decode_audio(section.file, min(dur, pr.audio_end - local_start), local_start, token)[:n]
        voice[:len(v)] = v
    mix = voice
    if options.music:
        if music:
            song = decode_audio(music, dur + 2, token=token)
        else:
            song = compose_music(options.mood, dur + 2, music_seed)
        if len(song) > SR:
            reps = int(math.ceil(n / len(song)))  # repetir la canción si es más corta que el clip
            song = np.tile(song, (reps, 1))[:n]
            mix = voice + song * level_envelope(words, start, end, dur, n)[:, None]
    raw = workdir / f"{out.stem}-mix.f32"
    mix.astype(np.float32).tofile(raw)
    audio_in = ["-f", "f32le", "-ar", str(SR), "-ac", "2", "-i", str(raw)]
    measure = run_capture("ffmpeg", ["-hide_banner"] + audio_in + ["-af", "loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"], token)
    filt = "loudnorm=I=-14:TP=-1.5:LRA=11"
    try:
        j = json.loads(measure[measure.rindex("{"):measure.rindex("}") + 1])
        if float(j["input_i"]) > -70:
            filt += (f":measured_I={j['input_i']}:measured_TP={j['input_tp']}:measured_LRA={j['input_lra']}"
                     f":measured_thresh={j['input_thresh']}:offset={j['target_offset']}:linear=true")
    except (ValueError, KeyError):
        pass
    # Entrada y salida suaves del sonido para que el clip no empiece ni acabe en seco.
    filt += f",afade=t=in:d=0.06,afade=t=out:st={max(0, dur - 0.35):.3f}:d=0.35,aresample=48000"

    fps = min(60, max(24, round(pr.fps)))
    out.unlink(missing_ok=True)
    enc = popen("ffmpeg", ["-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{Rw}x{Rh}", "-r", str(fps), "-i", "-"]
                + audio_in + ["-map", "0:v", "-map", "1:a", "-af", filt, "-t", f"{dur:.3f}",
                              "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p", "-profile:v", "high",
                              "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", str(out)], binary_stdin=True)
    enc_err = []
    threading.Thread(target=lambda: enc_err.append(enc.stderr.read()), daemon=True).start()
    total = int(round(dur * fps))
    reader = FrameReader(section.file, local_start, dur + 0.5, f"fps={fps}", src_w, src_h, "rgb24", token)
    k = 0
    try:
        last = None
        for frame in reader:
            if k >= total:
                break
            t = k / fps
            cx, cy, zoom = plan.at(t)
            if fit:
                img = _cover_blur(frame, R)
                fs = Rw / src_w * (1 + (zoom - 1) * 0.6)
                fg = cv2.resize(frame, (max(1, int(round(src_w * fs))), max(1, int(round(src_h * fs)))), interpolation=cv2.INTER_LANCZOS4)
                fx = int(round((Rw - fg.shape[1]) / 2))
                fy = int(round((Rh - fg.shape[0]) / 2 - Rh * 0.04))
                x0, y0 = max(0, fx), max(0, fy)
                x1, y1 = min(Rw, fx + fg.shape[1]), min(Rh, fy + fg.shape[0])
                img[y0:y1, x0:x1] = fg[y0 - fy:y1 - fy, x0 - fx:x1 - fx]
            else:
                s = base_scale * zoom
                w, h = Rw / s, Rh / s
                # El sujeto queda un poco por encima del centro (aire para los subtítulos).
                X = min(max(cx * src_w, w / 2), src_w - w / 2)
                Y = min(max(cy * src_h + h * 0.08, h / 2), src_h - h / 2)
                M = np.float32([[s, 0, -(X - w / 2) * s], [0, s, -(Y - h / 2) * s]])
                # Escalado Lanczos (más nítido que el lineal al ampliar el recorte).
                img = cv2.warpAffine(frame, M, (Rw, Rh), flags=cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REPLICATE)
            # Enfoque suave para compensar la ampliación.
            img = cv2.addWeighted(img, 1.35, cv2.GaussianBlur(img, (0, 0), 1.4), -0.35, 0)
            sub = next((c for c in subs if c.start <= t < c.end), None)
            if sub:
                draw_subtitle(img, sub, t)
            if hk and hk.start <= t < hk.end:
                draw_hook(img, hk, t)
            enc.stdin.write(img.tobytes())
            last = img
            k += 1
        token.check()
        # Si el trozo trae algún fotograma menos, se repite el último hasta completar la duración.
        while last is not None and k < total:
            enc.stdin.write(last.tobytes())
            k += 1
        enc.stdin.close()
        enc.wait()
    except (BrokenPipeError, OSError):
        token.check()
        raise ClipsError("Falló el montaje del clip: " + (b"".join(x for x in enc_err if x).decode("utf-8", "replace").strip()[-200:] or "error desconocido") + ".")
    finally:
        reader.close()
        if enc.poll() is None:
            kill_tree(enc)
        procs.remove(enc)
        raw.unlink(missing_ok=True)
    token.check()
    if k == 0:
        raise ClipsError("No se pudo leer la imagen del trozo descargado.")
    if enc.returncode != 0:
        raise ClipsError("Falló el montaje del clip: " + (b"".join(x for x in enc_err if x).decode("utf-8", "replace").strip()[-200:] or "error desconocido") + ".")
    return dur


def thumbnail(file: Path, at: float, out: Path, token: CancelToken = NEVER) -> Path | None:
    try:
        run("ffmpeg", ["-v", "error", "-y", "-ss", f"{max(0, at):.2f}", "-i", str(file), "-frames:v", "1",
                       "-vf", "scale=720:720:force_original_aspect_ratio=decrease", "-q:v", "3", str(out)], token=token)
        return out if out.exists() else None
    except ClipsError:
        return None
