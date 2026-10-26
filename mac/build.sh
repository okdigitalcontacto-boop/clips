#!/bin/zsh
# © 2026 OK Digital. Todos los derechos reservados.
# Compila Clips.app y la deja en el Escritorio, o en la ruta que se pase:
#   ./build.sh                       -> ~/Desktop/Clips.app
set -eo pipefail
cd "$(dirname "$0")"
APP="${1:-$HOME/Desktop/Clips.app}"
BUILD=../build
rm -rf "$BUILD" && mkdir -p "$BUILD"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 Core.swift Render.swift Music.swift Sound.swift App.swift UI.swift -o "$BUILD/Clips-arm64"
swiftc -O -swift-version 5 -parse-as-library -target x86_64-apple-macos14.0 Core.swift Render.swift Music.swift Sound.swift App.swift UI.swift -o "$BUILD/Clips-x86_64"
lipo -create "$BUILD/Clips-arm64" "$BUILD/Clips-x86_64" -output "$BUILD/Clips"
swift icon.swift "$BUILD/Clips.iconset" >/dev/null
iconutil -c icns "$BUILD/Clips.iconset" -o "$BUILD/Clips.icns"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Clips" "$APP/Contents/MacOS/Clips"
cp "$BUILD/Clips.icns" "$APP/Contents/Resources/Clips.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Clips</string>
  <key>CFBundleDisplayName</key><string>Clips</string>
  <key>CFBundleIdentifier</key><string>com.okdigital.clips</string>
  <key>CFBundleExecutable</key><string>Clips</string>
  <key>CFBundleIconFile</key><string>Clips</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 OK Digital. Todos los derechos reservados.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Listo: $APP"
