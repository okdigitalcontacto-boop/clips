# Clips para Windows · © 2026 OK Digital. Todos los derechos reservados.
"""Rutas, ajustes, procesos externos (yt-dlp, ffmpeg), portapapeles y errores."""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

WINDOWS = sys.platform == "win32"
APP_NAME = "Clips"
VERSION = "1.0.0"
COPYRIGHT = "© 2026 OK Digital. Todos los derechos reservados."


# MARK: - Errores

class ClipsError(Exception):
    def __init__(self, message: str, can_update_tools: bool = False, fatal: bool = False, opens_settings: bool = False):
        super().__init__(message)
        self.message = message
        self.can_update_tools = can_update_tools
        # No tiene sentido probar con otro modelo (clave mala, sin internet).
        self.fatal = fatal
        # El error se arregla en Ajustes (falta la clave o no vale).
        self.opens_settings = opens_settings


class Cancelled(Exception):
    pass


def fmt(s: float, tenths: bool = False) -> str:
    t = max(0.0, s)
    whole = int(t)
    h, m, sec = whole // 3600, (whole % 3600) // 60, whole % 60
    r = f"{h}:{m:02d}:{sec:02d}" if h > 0 else f"{m}:{sec:02d}"
    if tenths:
        r += f".{int((t - whole) * 10)}"
    return r


# MARK: - Rutas

def resource_dir() -> Path:
    """Archivos de la app (interfaz, fuentes, modelo de caras)."""
    if getattr(sys, "frozen", False):
        return Path(getattr(sys, "_MEIPASS", Path(sys.executable).parent))
    return Path(__file__).resolve().parent.parent


def app_dir() -> Path:
    """Carpeta donde está Clips.exe (las herramientas van en bin\\ al lado)."""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).parent
    return Path(__file__).resolve().parent.parent


def data_dir() -> Path:
    if WINDOWS:
        base = Path(os.environ.get("APPDATA") or Path.home() / "AppData/Roaming")
    elif sys.platform == "darwin":
        base = Path.home() / "Library/Application Support"
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    d = base / APP_NAME
    d.mkdir(parents=True, exist_ok=True)
    return d


def local_dir() -> Path:
    """Datos que no viajan con el perfil: caché de trabajo y yt-dlp actualizado."""
    if WINDOWS:
        base = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData/Local")
        d = base / APP_NAME
    else:
        d = data_dir() / "local"
    d.mkdir(parents=True, exist_ok=True)
    return d


def cache_root() -> Path:
    d = local_dir() / "Cache"
    d.mkdir(parents=True, exist_ok=True)
    return d


def videos_dir() -> Path:
    """La carpeta Vídeos del usuario (aunque la haya movido a otro disco)."""
    if WINDOWS:
        try:
            import ctypes
            from ctypes import wintypes
            import uuid

            class GUID(ctypes.Structure):
                _fields_ = [("Data1", wintypes.DWORD), ("Data2", wintypes.WORD), ("Data3", wintypes.WORD), ("Data4", ctypes.c_ubyte * 8)]

            u = uuid.UUID("{18989B1D-99B5-455B-841C-AB7C74E4DDFC}")  # FOLDERID_Videos
            g = GUID(u.fields[0], u.fields[1], u.fields[2], (ctypes.c_ubyte * 8)(*u.bytes[8:]))
            p = ctypes.c_wchar_p()
            shell32 = ctypes.windll.shell32
            shell32.SHGetKnownFolderPath.argtypes = [ctypes.POINTER(GUID), wintypes.DWORD, wintypes.HANDLE, ctypes.POINTER(ctypes.c_wchar_p)]
            if shell32.SHGetKnownFolderPath(ctypes.byref(g), 0, None, ctypes.byref(p)) == 0 and p.value:
                path = Path(p.value)
                ctypes.windll.ole32.CoTaskMemFree(p)
                return path
        except Exception:
            pass
        return Path.home() / "Videos"
    if sys.platform == "darwin":
        return Path.home() / "Movies"
    return Path.home() / "Videos"


# MARK: - Ajustes

class Settings:
    """Ajustes guardados en %APPDATA%\\Clips\\settings.json."""

    def __init__(self) -> None:
        self.path = data_dir() / "settings.json"
        self.lock = threading.Lock()
        try:
            self.values = json.loads(self.path.read_text("utf-8"))
        except Exception:
            self.values = {}
        # Falso en el modo prueba, para no tocar los ajustes de la persona.
        self.persist = True

    def get(self, key, default=None):
        with self.lock:
            return self.values.get(key, default)

    def set(self, key, value) -> None:
        with self.lock:
            self.values[key] = value
            if not self.persist:
                return
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.values, ensure_ascii=False, indent=2), "utf-8")
            os.replace(tmp, self.path)


settings = Settings()


# MARK: - Procesos externos (yt-dlp, ffmpeg)

def bin_dirs() -> list[Path]:
    dirs = [local_dir() / "bin", app_dir() / "bin"]
    if not WINDOWS:
        dirs += [Path("/opt/homebrew/bin"), Path("/usr/local/bin"), Path("/usr/bin")]
    return dirs


def tool_path(name: str) -> str | None:
    exe = name + (".exe" if WINDOWS else "")
    for d in bin_dirs():
        p = d / exe
        if p.is_file():
            return str(p)
    return shutil.which(name)


def tool_env() -> dict:
    env = dict(os.environ)
    extra = os.pathsep.join(str(d) for d in bin_dirs() if d.is_dir())
    env["PATH"] = extra + os.pathsep + env.get("PATH", "")
    env["PYTHONIOENCODING"] = "utf-8"
    return env


NO_WINDOW = 0x08000000 if WINDOWS else 0  # CREATE_NO_WINDOW: sin ventanas negras de consola


class Procs:
    """Procesos en marcha, para poder cancelarlos todos de golpe (con sus hijos)."""

    def __init__(self) -> None:
        self.running: set[subprocess.Popen] = set()
        self.lock = threading.Lock()

    def add(self, p):
        with self.lock:
            self.running.add(p)

    def remove(self, p):
        with self.lock:
            self.running.discard(p)

    def kill_all(self) -> None:
        with self.lock:
            ps = list(self.running)
        for p in ps:
            kill_tree(p)


procs = Procs()


def kill_tree(p: subprocess.Popen) -> None:
    """yt-dlp lanza ffmpeg, que si no se mata sigue descargando: se mata el árbol entero."""
    if p.poll() is not None:
        return
    try:
        if WINDOWS:
            subprocess.run(["taskkill", "/PID", str(p.pid), "/T", "/F"], capture_output=True, creationflags=NO_WINDOW)
        else:
            os.killpg(os.getpgid(p.pid), signal.SIGTERM)
    except Exception:
        try:
            p.kill()
        except Exception:
            pass


class CancelToken:
    def __init__(self) -> None:
        self.event = threading.Event()

    @property
    def cancelled(self) -> bool:
        return self.event.is_set()

    def check(self) -> None:
        if self.event.is_set():
            raise Cancelled()

    def sleep(self, seconds: float) -> None:
        if self.event.wait(seconds):
            raise Cancelled()


NEVER = CancelToken()


def popen(exe: str, args: list[str], binary_stdin: bool = False) -> subprocess.Popen:
    path = tool_path(exe)
    if not path:
        raise ClipsError(f"No encuentro {exe}. Vuelve a descargar Clips: debería venir dentro, en la carpeta bin.")
    kw = dict(stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=tool_env(), creationflags=NO_WINDOW)
    kw["stdin"] = subprocess.PIPE if binary_stdin else subprocess.DEVNULL
    if not WINDOWS:
        kw["start_new_session"] = True
    try:
        p = subprocess.Popen([path] + args, **kw)
    except OSError:
        raise ClipsError(f"No he podido abrir {exe}.")
    procs.add(p)
    return p


def _pump(stream, sink: list, on_line) -> None:
    pending = b""
    while True:
        chunk = stream.read1(65536) if hasattr(stream, "read1") else stream.read(65536)
        if not chunk:
            break
        sink.append(chunk)
        if on_line is None:
            continue
        pending += chunk
        parts = re.split(rb"[\r\n]", pending)
        pending = parts.pop()
        for line in parts:
            if line:
                on_line(line.decode("utf-8", "replace"))


def run_sync(exe: str, args: list[str], on_line=None, token: CancelToken = NEVER) -> tuple[int, bytes, str]:
    p = popen(exe, args)
    out, err = [], []
    threads = [threading.Thread(target=_pump, args=(p.stdout, out, on_line), daemon=True),
               threading.Thread(target=_pump, args=(p.stderr, err, on_line), daemon=True)]
    for t in threads:
        t.start()
    try:
        while p.poll() is None:
            if token.cancelled:
                kill_tree(p)
            time.sleep(0.05)
        # Si un proceso hijo se quedó con la tubería abierta, no esperarlo para siempre.
        for t in threads:
            t.join(timeout=3)
    finally:
        procs.remove(p)
    token.check()
    return p.returncode, b"".join(out), b"".join(err).decode("utf-8", "replace")


def explain_tool_error(exe: str, err: str) -> ClipsError:
    """Traduce los fallos típicos de yt-dlp a algo que se entienda."""
    e = err.lower()
    if exe == "yt-dlp":
        if "private video" in e or "video unavailable" in e or "has been removed" in e:
            return ClipsError("El vídeo no está disponible: es privado, se ha borrado o está bloqueado.")
        if "sign in to confirm your age" in e or "age-restricted" in e:
            return ClipsError("El vídeo tiene restricción de edad y YouTube no deja descargarlo sin iniciar sesión.")
        if "unsupported url" in e or "is not a valid url" in e:
            return ClipsError("Ese enlace no es de un vídeo de YouTube.")
        if any(k in e for k in ("unable to resolve host", "getaddrinfo failed", "nodename nor servname", "network is unreachable", "failed to resolve")):
            return ClipsError("No hay conexión a internet.")
        if "not a bot" in e:
            return ClipsError("YouTube está frenando las descargas desde tu conexión (pide confirmar que no eres un robot). "
                              "Actualiza yt-dlp o espera un rato y vuelve a probar.", can_update_tools=True)
        if any(k in e for k in ("sign in to confirm", "unable to extract", "http error 403", "nsig", "requested format is not available", "js runtime")):
            return ClipsError("YouTube ha cambiado algo y hay que actualizar yt-dlp.", can_update_tools=True)
    lines = [l for l in err.splitlines() if l.strip() and "WARNING" not in l]
    return ClipsError(f"{exe} falló. " + "\n".join(lines[-2:]), can_update_tools=exe == "yt-dlp")


def run(exe: str, args: list[str], on_line=None, token: CancelToken = NEVER) -> bytes:
    code, data, err = run_sync(exe, args, on_line, token)
    if code != 0:
        raise explain_tool_error(exe, err)
    return data


def run_capture(exe: str, args: list[str], token: CancelToken = NEVER) -> str:
    """Como `run`, pero devuelve lo que el programa escribe en stderr (ffmpeg informa ahí de sus mediciones)."""
    code, _, err = run_sync(exe, args, None, token)
    if code != 0:
        raise explain_tool_error(exe, err)
    return err


def ytdlp_base() -> list[str]:
    """Opciones comunes: dónde está ffmpeg y qué motor de JavaScript usar (YouTube lo exige)."""
    args = ["--no-playlist", "--no-warnings"]
    ff = tool_path("ffmpeg")
    if ff:
        args += ["--ffmpeg-location", str(Path(ff).parent)]
    deno = tool_path("deno")
    if deno:
        args += ["--js-runtimes", f"deno:{deno}"]
    return args


# MARK: - Portapapeles, carpetas y navegador

def _win_clipboard():
    import ctypes
    from ctypes import wintypes
    u32 = ctypes.WinDLL("user32", use_last_error=True)
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    u32.OpenClipboard.argtypes = [wintypes.HWND]; u32.OpenClipboard.restype = wintypes.BOOL
    u32.CloseClipboard.restype = wintypes.BOOL
    u32.EmptyClipboard.restype = wintypes.BOOL
    u32.GetClipboardData.argtypes = [wintypes.UINT]; u32.GetClipboardData.restype = wintypes.HANDLE
    u32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]; u32.SetClipboardData.restype = wintypes.HANDLE
    k32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]; k32.GlobalAlloc.restype = wintypes.HGLOBAL
    k32.GlobalLock.argtypes = [wintypes.HGLOBAL]; k32.GlobalLock.restype = wintypes.LPVOID
    k32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]; k32.GlobalUnlock.restype = wintypes.BOOL
    return ctypes, u32, k32


def _win_open_clipboard(u32) -> bool:
    for _ in range(10):
        if u32.OpenClipboard(None):
            return True
        time.sleep(0.03)
    return False


def clipboard_get() -> str:
    try:
        if WINDOWS:
            ctypes, u32, k32 = _win_clipboard()
            if not _win_open_clipboard(u32):
                return ""
            try:
                h = u32.GetClipboardData(13)  # CF_UNICODETEXT
                if not h:
                    return ""
                p = k32.GlobalLock(h)
                if not p:
                    return ""
                try:
                    return ctypes.wstring_at(p)
                finally:
                    k32.GlobalUnlock(h)
            finally:
                u32.CloseClipboard()
        if sys.platform == "darwin":
            return subprocess.run(["pbpaste"], capture_output=True, env={**os.environ, "LANG": "en_US.UTF-8"}).stdout.decode("utf-8", "replace")
    except Exception:
        pass
    return ""


def clipboard_set(text: str) -> None:
    try:
        if WINDOWS:
            ctypes, u32, k32 = _win_clipboard()
            data = (text + "\0").encode("utf-16-le")
            h = k32.GlobalAlloc(0x0002, len(data))  # GMEM_MOVEABLE
            p = k32.GlobalLock(h)
            ctypes.memmove(p, data, len(data))
            k32.GlobalUnlock(h)
            if not _win_open_clipboard(u32):
                return
            try:
                u32.EmptyClipboard()
                u32.SetClipboardData(13, h)
            finally:
                u32.CloseClipboard()
        elif sys.platform == "darwin":
            subprocess.run(["pbcopy"], input=text.encode("utf-8"), env={**os.environ, "LANG": "en_US.UTF-8"})
    except Exception:
        pass


def reveal(path: Path) -> None:
    """Muestra el archivo seleccionado en el Explorador (o en Finder)."""
    if WINDOWS:
        subprocess.Popen(["explorer", f"/select,{path}"], creationflags=NO_WINDOW)
    elif sys.platform == "darwin":
        subprocess.Popen(["open", "-R", str(path)])


def open_folder(path: Path) -> None:
    if WINDOWS:
        os.startfile(str(path))  # type: ignore[attr-defined]
    elif sys.platform == "darwin":
        subprocess.Popen(["open", str(path)])


def open_url(url: str) -> None:
    import webbrowser
    webbrowser.open(url)


def safe_name(s: str) -> str:
    # En Windows tampoco valen estos nombres ni acabar en punto o espacio.
    r = re.sub(r'[/:\\?%*|"<>\n\r\t]', " ", s)
    r = re.sub(r"\s{2,}", " ", r).strip()
    r = r.lstrip(".")
    r = (r or "Clip")[:60].strip().rstrip(". ")
    if r.upper() in {"CON", "PRN", "AUX", "NUL"} or re.fullmatch(r"(?i)(COM|LPT)\d", r):
        r = "_" + r
    return r or "Clip"
