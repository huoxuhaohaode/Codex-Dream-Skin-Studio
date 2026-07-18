#!/bin/bash

set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd -P)/common-macos.sh"

THEME_ID=""
OUTPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --id) THEME_ID="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) fail "Unknown export argument: $1" ;;
  esac
done
case "$THEME_ID" in ''|*[!A-Za-z0-9_-]*) fail "Theme id is invalid." ;; esac
[ -n "$OUTPUT" ] || fail "Usage: export-theme-macos.sh --id <theme-id> --output <file.dreamskin>"
case "$OUTPUT" in *.dreamskin|*.codexskin) ;; *) OUTPUT="$OUTPUT.dreamskin" ;; esac

ensure_state_root
ensure_node_runtime
SOURCE="$STATE_ROOT/themes/$THEME_ID"
[ -d "$SOURCE" ] && [ ! -L "$SOURCE" ] || fail "Theme not found: $THEME_ID"
case "$THEME_ID" in custom-?*) ;; *) fail "Only themes created in this app can be exported." ;; esac
if [ -e "$SOURCE/origin.json" ] || [ -L "$SOURCE/origin.json" ]; then
  [ ! -L "$SOURCE/origin.json" ] || fail "Theme origin metadata must not be a symbolic link."
  origin_verified="$("$NODE" -e '
    const fs = require("fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (!value || typeof value !== "object" || Array.isArray(value)) process.exit(1);
    process.stdout.write(value.verified === true ? "true" : "false");
  ' "$SOURCE/origin.json")" || fail "Theme origin metadata is invalid."
  [ "$origin_verified" != "true" ] \
    || fail "Verified community themes must be shared from their original source, not repackaged."
fi
[ ! -e "$OUTPUT" ] || fail "Export destination already exists."

if [[ "$OUTPUT" == *.codexskin ]]; then
  "$NODE" "$SCRIPT_DIR/theme-package.mjs" export \
    --source "$SOURCE" \
    --output "$OUTPUT" \
    --injector "$INJECTOR" \
    --stage-theme "$SCRIPT_DIR/stage-theme.mjs"
  exit 0
fi

temporary="$(/usr/bin/mktemp -d "$STATE_ROOT/.theme-export.XXXXXX")"
cleanup_export() { /bin/rm -rf "$temporary"; }
trap cleanup_export EXIT
"$NODE" "$SCRIPT_DIR/stage-theme.mjs" "$SOURCE" "$temporary" >/dev/null
"$NODE" "$INJECTOR" --check-payload --theme-dir "$temporary" >/dev/null
"$NODE" "$SCRIPT_DIR/dreamskin-package.mjs" export "$temporary" "$OUTPUT"
