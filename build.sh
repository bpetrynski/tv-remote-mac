#!/bin/bash
# Builds "TV Remote.app" into ~/Applications. Run again after changing App/ or Drivers/.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/TV Remote.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Icon: generated once, then only copied (swift make-icon.swift takes a few seconds).
if [ ! -f "$SRC/AppIcon.icns" ]; then
    swift "$SRC/make-icon.swift" "$SRC"
fi
cp "$SRC/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Script drivers and the guide for writing new ones.
mkdir -p "$APP/Contents/Resources/Drivers"
rsync -a --exclude '__pycache__' "$SRC/Drivers/" "$APP/Contents/Resources/Drivers/"
cp "$SRC/DRIVERS.md" "$APP/Contents/Resources/DRIVERS.md"

swiftc -O -parse-as-library \
    -target arm64-apple-macosx15.0 \
    "$SRC"/App/*.swift \
    -o "$APP/Contents/MacOS/TVRemote"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>TV Remote</string>
    <key>CFBundleDisplayName</key>     <string>TV Remote</string>
    <key>CFBundleIdentifier</key>      <string>io.github.bpetrynski.tvremote</string>
    <key>CFBundleExecutable</key>      <string>TVRemote</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>2.0</string>
    <key>CFBundleVersion</key>         <string>2</string>
    <key>LSMinimumSystemVersion</key>  <string>15.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>TV Remote finds and controls TVs on your local network.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_companion-link._tcp</string>
        <string>_airplay._tcp</string>
        <string>_androidtvremote2._tcp</string>
    </array>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key> <true/>
    </dict>
</dict>
</plist>
PLIST

# Same certificate every build: macOS keeps the Local Network permission (see make-cert.sh).
# Without it the signature is ad hoc and the permission has to be granted after each build.
IDENTITY="${TVREMOTE_SIGN_IDENTITY:-TV Remote Local Signing}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
    echo "Signed ad hoc: run ./make-cert.sh once to keep the Local Network permission across builds."
fi

echo "Built: $APP"
