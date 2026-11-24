#!/bin/bash
# Baut FritzThermo.app – benötigt nur die Xcode Command Line Tools
# (einmalig installieren mit:  xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

APP="FritzThermo.app"
ARCH="$(uname -m)"   # arm64 (Apple Silicon) oder x86_64 (Intel)

echo "→ Kompiliere für $ARCH …"
rm -rf build "$APP"
mkdir -p build
swiftc -O -parse-as-library \
  -target "${ARCH}-apple-macos13.0" \
  Sources/FritzThermo.swift \
  -o build/FritzThermo

echo "→ Erstelle App-Bundle …"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/FritzThermo "$APP/Contents/MacOS/FritzThermo"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo
echo "✅ Fertig: $(pwd)/$APP"
echo "   Installieren:  mv $APP /Applications/ && open /Applications/$APP"
