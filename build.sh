#!/bin/bash
set -e
cd "$(dirname "$0")"

OUTPUT_DIR="./build"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

build_app() {
    local NAME=$1
    local DISPLAY_NAME=$2
    local BUNDLE_ID=$3
    local SOURCE=$4

    echo "Building $DISPLAY_NAME..."

    local APP_DIR="$OUTPUT_DIR/$DISPLAY_NAME.app/Contents"
    mkdir -p "$APP_DIR/MacOS"

    # Compile
    swiftc -O -whole-module-optimization \
        -target x86_64-apple-macosx10.14 \
        -sdk $(xcrun --show-sdk-path) \
        -framework Cocoa -framework CoreMIDI \
        -o "$APP_DIR/MacOS/$NAME" \
        "$SOURCE"

    # Info.plist
    cat > "$APP_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.14</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>MIDIShare uses the local network to send and receive MIDI data.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_midishare._tcp</string>
    </array>
</dict>
</plist>
PLIST

    echo "  -> $OUTPUT_DIR/$DISPLAY_NAME.app"
}

build_app "MIDIShareServer" "MIDIShare Server" "com.midishare.server" \
    "Sources/MIDIShareServer/main.swift"

build_app "MIDIShareClient" "MIDIShare Client" "com.midishare.client" \
    "Sources/MIDIShareClient/main.swift"

echo ""
echo "Build complete!"
echo "  $OUTPUT_DIR/MIDIShare Server.app"
echo "  $OUTPUT_DIR/MIDIShare Client.app"
echo ""
echo "Copy each .app to the appropriate machine and double-click to run."
