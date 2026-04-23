#!/usr/bin/env bash
# Build the SPM executable and wrap it in a minimal .app bundle with
# LSUIElement=true so it runs as a menubar-only app (no Dock icon).
set -euo pipefail

cd "$(dirname "$0")"

swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)
APP="AudioFollower.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AudioFollower" "$APP/Contents/MacOS/AudioFollower"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AudioFollower</string>
    <key>CFBundleIdentifier</key><string>com.mtklein.AudioFollower</string>
    <key>CFBundleName</key><string>AudioFollower</string>
    <key>CFBundleDisplayName</key><string>Audio Follower</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS will launch it without quarantine nags.
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
echo "Run: open $APP"
