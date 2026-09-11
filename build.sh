#!/bin/bash
# Compile ScannerDiapo.app (pas besoin de Xcode, juste les outils en ligne de commande : xcode-select --install)
# Usage : ./build.sh              → compile et installe dans /Applications
#         ./build.sh --no-install → laisse ScannerDiapo.app dans ce dossier
set -e
cd "$(dirname "$0")"
APP="ScannerDiapo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Binaire universel : Apple Silicon + Intel
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target $arch-apple-macos13 main.swift -o "ScannerDiapo-$arch" \
    -framework SwiftUI -framework AVFoundation -framework CoreImage
done
lipo -create ScannerDiapo-arm64 ScannerDiapo-x86_64 -output "$APP/Contents/MacOS/ScannerDiapo"
rm ScannerDiapo-arm64 ScannerDiapo-x86_64
# Icône : régénérée avec « swift icon.swift && iconutil -c icns AppIcon.iconset » si on la modifie
cp AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Scanner de diapos</string>
  <key>CFBundleDisplayName</key><string>Scanner de diapos</string>
  <key>CFBundleIdentifier</key><string>io.github.meutedechien.scannerdiapo</string>
  <key>CFBundleExecutable</key><string>ScannerDiapo</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Le micro sert à déclencher un scan en claquant des mains.</string>
  <key>NSCameraUsageDescription</key><string>Le scanner de diapos se présente comme une caméra USB.</string>
</dict></plist>
EOF
codesign --force --sign - "$APP"
if [ "$1" = "--no-install" ]; then
  echo "OK : $(pwd)/$APP"
  exit 0
fi
# Installation dans /Applications (on quitte l'ancienne version si elle tourne)
pkill -x ScannerDiapo 2>/dev/null || true
rm -rf "/Applications/$APP"
mv "$APP" /Applications/
echo "OK : /Applications/$APP"
