#!/bin/zsh
set -eu
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_APP="$TASK_ROOT/build/照片轻装.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources" "$TASK_ROOT/build/module-cache"
swift -module-cache-path "$TASK_ROOT/build/module-cache" "$TASK_ROOT/scripts/icon.swift" "$TASK_ROOT"
iconutil -c icns "$TASK_ROOT/build/AppIcon.iconset" -o "$TASK_ROOT/Resources/AppIcon.icns"
cp "$TASK_ROOT/Resources/AppIcon.icns" "$TASK_ROOT/Resources/AppIcon.png" "$TASK_APP/Contents/Resources/"
swiftc -parse-as-library -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$TASK_ROOT/build/module-cache" \
  "$TASK_ROOT"/Sources/*.swift -o "$TASK_APP/Contents/MacOS/PhotoCompressor"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PhotoCompressor</string>
<key>CFBundleIdentifier</key><string>local.photo-compressor</string>
<key>CFBundleName</key><string>照片轻装</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$TASK_APP"
echo "$TASK_APP"
