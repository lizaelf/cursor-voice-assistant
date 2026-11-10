#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/dist/Voice.app"
support="$HOME/Library/Application Support/Voice"
keychain="$support/voice.keychain-db"
identity="Voice Local"

mkdir -p "$app/Contents/MacOS"
swiftc -O -target x86_64-apple-macos12.0 \
  -o "$app/Contents/MacOS/Voice" \
  "$root/macos/Voice/main.swift" \
  "$root/macos/Voice/VoiceCore.swift" \
  "$root/macos/Voice/WifiSetup.swift" \
  -framework AppKit \
  -framework AVFoundation \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework Network \
  -framework Security
cp "$root/macos/Voice/Info.plist" "$app/Contents/Info.plist"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$identity"; then
  codesign --force --sign "$identity" "$app"
else
  codesign --force --sign - "$app"
fi

echo "Зібрано $app"
