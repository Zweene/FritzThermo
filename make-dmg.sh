#!/bin/bash
# Erstellt FritzThermo-<Version>.dmg (Universal: Apple Silicon + Intel)
# Aufruf:  ./make-dmg.sh 1.0
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.0}"
APP="FritzThermo.app"
DMG="FritzThermo-${VERSION}.dmg"

rm -rf build "$APP" "$DMG" dmg-staging
mkdir -p build

for ARCH in arm64 x86_64; do
  echo "→ Kompiliere für $ARCH …"
  swiftc -O -parse-as-library \
    -target "${ARCH}-apple-macos13.0" \
    Sources/FritzThermo.swift \
    -o "build/FritzThermo-${ARCH}"
done

echo "→ Universal-Binary erstellen …"
lipo -create build/FritzThermo-arm64 build/FritzThermo-x86_64 -output build/FritzThermo

echo "→ App-Bundle erstellen …"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/FritzThermo "$APP/Contents/MacOS/FritzThermo"
sed -e "/CFBundleShortVersionString/{n;s#<string>.*</string>#<string>${VERSION}</string>#;}" \
    Info.plist > "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "→ DMG erstellen …"
mkdir dmg-staging
cp -R "$APP" dmg-staging/
ln -s /Applications dmg-staging/Programme
hdiutil create -volname "FritzThermo" -srcfolder dmg-staging -ov -format UDZO "$DMG" >/dev/null
rm -rf dmg-staging

echo
echo "✅ Fertig: $(pwd)/$DMG"
