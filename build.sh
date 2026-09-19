#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
app="$PWD/Local Subtitles.app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
  -module-cache-path "${TMPDIR:-/tmp}/LocalSubtitles-swift-cache" \
  LocalSubtitles.swift -o "$app/Contents/MacOS/LocalSubtitles"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
printf '%s\n' "$app"
