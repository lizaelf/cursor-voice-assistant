#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$(mktemp)"
trap 'rm -f "$out"' EXIT

swiftc -target x86_64-apple-macos12.0 \
  -o "$out" \
  "$root/macos/Voice/VoiceCore.swift" \
  "$root/macos/VoiceTests/main.swift"

"$out"
