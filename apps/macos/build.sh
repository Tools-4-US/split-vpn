#!/bin/bash
# Compila e empacota o Geleit.app (binário universal arm64 + x86_64, assinatura ad-hoc).
#   ./build.sh            → build/Geleit.app
#   ./build.sh --zip      → também build/Geleit-macOS.zip + .sha256 (para distribuição)
#   ./build.sh --install  → também copia para /Applications
# VERSION=1.2.3 ./build.sh define a versão exibida no app (padrão: 0.0.0-dev).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Geleit.app"
VERSION="${VERSION:-0.0.0-dev}"
# Uma arquitetura por vez + lipo: o build multi-arch do SwiftPM (--arch a --arch b) falha
# em algumas versões do Xcode com "duplicate output file".
for arch in arm64 x86_64; do
  swift build -c release --arch "$arch"
done
mkdir -p build
lipo -create .build/arm64-apple-macosx/release/Geleit .build/x86_64-apple-macosx/release/Geleit \
  -output build/Geleit-universal

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv build/Geleit-universal "$APP/Contents/MacOS/Geleit"

# Ícones fornecidos (opcionais): MenuBarIcon*.pdf|svg|png e AppIcon.icns ou AppIcon.png (1024x1024)
shopt -s nullglob
for f in Resources/MenuBarIcon*.{pdf,svg,png}; do cp "$f" "$APP/Contents/Resources/"; done
install -m 0755 helper/geleit-helper install-helper.sh "$APP/Contents/Resources/"
ICON_KEY=""
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
elif [[ -f Resources/AppIcon.png ]]; then
  iconset=$(mktemp -d)/AppIcon.iconset; mkdir -p "$iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$APP/Contents/Resources/AppIcon.icns"
fi
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] && ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"

BUILD=$(git rev-parse --short HEAD 2>/dev/null || echo local)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Geleit</string>
  <key>CFBundleDisplayName</key><string>Geleit</string>
  <key>CFBundleIdentifier</key><string>io.github.tools4us.geleit</string>
  <key>CFBundleExecutable</key><string>Geleit</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  ${ICON_KEY}
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "OK: $APP"

if [[ " $* " == *" --zip "* ]]; then
  ZIP="build/Geleit-macOS.zip"
  rm -f "$ZIP" "$ZIP.sha256"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  (cd build && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
  echo "OK: $ZIP ($(du -h "$ZIP" | cut -f1))"
fi

if [[ " $* " == *" --install "* ]]; then
  pkill -x Geleit 2>/dev/null && sleep 1 || true
  rm -rf "/Applications/Geleit.app"
  cp -R "$APP" /Applications/
  echo "Instalado em /Applications/Geleit.app"
fi
