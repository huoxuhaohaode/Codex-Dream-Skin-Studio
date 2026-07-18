#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SOURCE="$ROOT/theme-switcher/ThemeSwitcherApp.swift"
PLIST="$ROOT/theme-switcher/Info.plist"
ICON_SOURCE="$ROOT/theme-switcher/Assets/AppIcon-1024.png"
OUTPUT="${1:-$ROOT/build/Codex Dream Skin Switcher.app}"
SWIFTC="$(/usr/bin/xcrun --find swiftc 2>/dev/null || true)"
SDK_PATH="${SDKROOT:-}"

[ -n "$SWIFTC" ] && [ -x "$SWIFTC" ] \
  || { printf 'Swift compiler not found. Install Apple Command Line Tools first.\n' >&2; exit 1; }
[ -f "$SOURCE" ] || { printf 'Theme switcher source is missing: %s\n' "$SOURCE" >&2; exit 1; }
[ -f "$PLIST" ] || { printf 'Theme switcher Info.plist is missing: %s\n' "$PLIST" >&2; exit 1; }
[ -f "$ICON_SOURCE" ] || { printf 'Theme switcher icon is missing: %s\n' "$ICON_SOURCE" >&2; exit 1; }

icon_width="$(/usr/bin/sips -g pixelWidth "$ICON_SOURCE" 2>/dev/null | /usr/bin/awk '/pixelWidth:/ { print $2 }')"
icon_height="$(/usr/bin/sips -g pixelHeight "$ICON_SOURCE" 2>/dev/null | /usr/bin/awk '/pixelHeight:/ { print $2 }')"
icon_alpha="$(/usr/bin/sips -g hasAlpha "$ICON_SOURCE" 2>/dev/null | /usr/bin/awk '/hasAlpha:/ { print $2 }')"
[ "$icon_width" = "1024" ] && [ "$icon_height" = "1024" ] \
  || { printf 'Theme switcher icon must be exactly 1024 x 1024 pixels.\n' >&2; exit 1; }
[ "$icon_alpha" = "yes" ] \
  || { printf 'Theme switcher icon must contain an alpha channel.\n' >&2; exit 1; }

if [ -z "$SDK_PATH" ]; then
  if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]; then
    SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
  else
    SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
  fi
fi

parent="$(dirname "$OUTPUT")"
stage="$parent/.Codex Dream Skin Switcher.building.$$"
module_cache="${TMPDIR:-/tmp}/codex-dream-skin-swift-cache"
cleanup_stage() { /bin/rm -rf "$stage"; }
trap cleanup_stage EXIT

/bin/mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
/bin/mkdir -p "$module_cache"
"$SWIFTC" \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -sdk "$SDK_PATH" \
  -module-cache-path "$module_cache" \
  -target "$(/usr/bin/uname -m)-apple-macos13.0" \
  -framework SwiftUI \
  -framework AppKit \
  -o "$stage/Contents/MacOS/DreamSkinSwitcher" \
  "$SOURCE"
/bin/cp "$PLIST" "$stage/Contents/Info.plist"
/bin/cp "$ICON_SOURCE" "$stage/Contents/Resources/AppIcon.png"
iconset="$stage/AppIcon.iconset"
/bin/mkdir -p "$iconset"
for spec in \
  '16 icon_16x16.png' \
  '32 icon_16x16@2x.png' \
  '32 icon_32x32.png' \
  '64 icon_32x32@2x.png' \
  '128 icon_128x128.png' \
  '256 icon_128x128@2x.png' \
  '256 icon_256x256.png' \
  '512 icon_256x256@2x.png' \
  '512 icon_512x512.png' \
  '1024 icon_512x512@2x.png'; do
  size="${spec%% *}"
  name="${spec#* }"
  /usr/bin/sips -z "$size" "$size" "$ICON_SOURCE" --out "$iconset/$name" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$stage/Contents/Resources/AppIcon.icns"
/bin/rm -rf "$iconset"
/bin/mkdir -p "$stage/Contents/Resources/engine"
for directory in assets presets scripts community; do
  /usr/bin/rsync -a "$ROOT/$directory/" "$stage/Contents/Resources/engine/$directory/"
done
/bin/cp "$ROOT/VERSION" "$stage/Contents/Resources/engine/VERSION"
/bin/chmod 755 "$stage/Contents/MacOS/DreamSkinSwitcher"
/bin/chmod 755 "$stage/Contents/Resources/engine/scripts/"*.sh
/usr/bin/codesign --force --sign - --timestamp=none "$stage" >/dev/null

/bin/rm -rf "$OUTPUT"
/bin/mv "$stage" "$OUTPUT"
trap - EXIT
printf 'Built %s\n' "$OUTPUT"
