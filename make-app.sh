#!/bin/bash
# Builds Geeves.app from source. Needs Xcode or the Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

echo "Building Geeves…"
swift build -c release

APP="build/Geeves.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Geeves" "$APP/Contents/MacOS/Geeves"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Geeves</string>
  <key>CFBundleDisplayName</key><string>Geeves</string>
  <key>CFBundleIdentifier</key><string>com.maggiefok.geeves</string>
  <key>CFBundleExecutable</key><string>Geeves</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will run it on this Mac.
codesign --force --deep --sign - "$APP"

echo ""
echo "Done: $(pwd)/$APP"
echo "Drag it into your Applications folder, then open it."
