# Clips para Windows · © 2026 OK Digital. Todos los derechos reservados.
# Compila Clips en un PC con Windows (lo mismo que hace GitHub Actions):
#   powershell -ExecutionPolicy Bypass -File build.ps1
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
python -m pip install -r requirements.txt pyinstaller==6.22.3
$bin = "tools"
New-Item -ItemType Directory -Force $bin | Out-Null
Invoke-WebRequest "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" -OutFile "$bin/yt-dlp.exe"
Invoke-WebRequest "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip" -OutFile ffmpeg.zip
Expand-Archive ffmpeg.zip -DestinationPath ffmpeg -Force
Copy-Item (Get-ChildItem ffmpeg -Recurse -Filter ffmpeg.exe).FullName $bin
Copy-Item (Get-ChildItem ffmpeg -Recurse -Filter ffprobe.exe).FullName $bin
Invoke-WebRequest "https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip" -OutFile deno.zip
Expand-Archive deno.zip -DestinationPath $bin -Force
python -m PyInstaller --noconfirm clips.spec
Copy-Item $bin "dist/Clips/bin" -Recurse -Force
Copy-Item ../LICENSE, ../THIRD_PARTY_NOTICES.md "dist/Clips/"
Copy-Item LEEME.txt "dist/Clips/"
$p = Start-Process "dist/Clips/Clips.exe" -ArgumentList "--selftest","--log","$PWD/selftest.log" -Wait -PassThru
Get-Content selftest.log
if ($p.ExitCode -ne 0) { throw "La prueba ha fallado" }
