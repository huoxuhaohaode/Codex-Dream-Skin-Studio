#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
VERSION="$(/usr/bin/tr -d '[:space:]' < "$ROOT/VERSION")"
RELEASE_DIR="$ROOT/release"
ARCHIVE="$RELEASE_DIR/Codex-Dream-Skin-Switcher-v$VERSION.zip"
CHECKSUM="$RELEASE_DIR/Codex-Dream-Skin-Switcher-v$VERSION.sha256"
TEMPORARY="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dream-skin-app-release.XXXXXX")"
APP="$TEMPORARY/Codex Dream Skin Switcher.app"
trap '/bin/rm -rf "$TEMPORARY"' EXIT

if [ "${1:-}" != "--skip-tests" ]; then
  "$ROOT/tests/run-tests.sh"
fi

/bin/mkdir -p "$RELEASE_DIR"
"$ROOT/scripts/build-theme-switcher-macos.sh" "$APP"
/usr/bin/codesign --verify --strict "$APP"
/bin/rm -f "$ARCHIVE" "$CHECKSUM"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --keepParent --norsrc --noextattr \
  "$APP" "$ARCHIVE"
SHA256="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
/usr/bin/printf '%s  %s\n' "$SHA256" "$(/usr/bin/basename "$ARCHIVE")" > "$CHECKSUM"
printf 'Created %s\nSHA-256 %s\n' "$ARCHIVE" "$SHA256"
