#!/bin/sh
# Builds Kleo.app in ./build. Usage: ./scripts/build-app.sh
set -eu
cd "$(dirname "$0")/.."

APP=build/Kleo.app
VERSION=1.0.0

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Kleo" "$APP/Contents/MacOS/Kleo"

ICONSET=build/Kleo.iconset
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Kleo.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Kleo</string>
  <key>CFBundleDisplayName</key><string>Kleo</string>
  <key>CFBundleIdentifier</key><string>io.github.s3raphine.kleo</string>
  <key>CFBundleExecutable</key><string>Kleo</string>
  <key>CFBundleIconFile</key><string>Kleo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP"
