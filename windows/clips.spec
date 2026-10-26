# Clips para Windows · © 2026 OK Digital. Todos los derechos reservados.
# pyinstaller clips.spec  ->  dist/Clips/Clips.exe (las herramientas van aparte, en dist/Clips/bin)
a = Analysis(
    ["main.py"],
    pathex=["."],
    datas=[("ui", "ui"), ("assets", "assets")],
    hiddenimports=["clips.selftest"],
    excludes=["tkinter", "matplotlib", "scipy", "IPython"],
)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="Clips", console=False,
          icon="assets/Clips.ico", version="version_info.txt", upx=False)
coll = COLLECT(exe, a.binaries, a.datas, name="Clips", upx=False)
