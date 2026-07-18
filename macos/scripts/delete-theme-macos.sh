#!/bin/bash

set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd -P)/common-macos.sh"

THEME_ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --id) THEME_ID="${2:-}"; shift 2 ;;
    *) fail "Unknown delete argument: $1" ;;
  esac
done

case "$THEME_ID" in
  custom-?*) ;;
  *) fail "Only custom-* themes can be deleted." ;;
esac
case "$THEME_ID" in
  *[!A-Za-z0-9_-]*) fail "Theme id may contain only letters, numbers, underscores, and hyphens." ;;
esac
[ "${#THEME_ID}" -le 80 ] || fail "Theme id is too long."

ensure_state_root
ensure_node_runtime
THEMES_ROOT="$STATE_ROOT/themes"
SOURCE="$THEMES_ROOT/$THEME_ID"
[ -d "$SOURCE" ] && [ ! -L "$SOURCE" ] || fail "Custom theme not found: $THEME_ID"
[ -f "$SOURCE/theme.json" ] && [ ! -L "$SOURCE/theme.json" ] \
  || fail "Custom theme metadata is missing or unsafe."

themes_real="$(cd "$THEMES_ROOT" && pwd -P)"
source_real="$(cd "$SOURCE" && pwd -P)"
case "$source_real/" in
  "$themes_real/custom-"*) ;;
  *) fail "Custom theme directory escapes the theme library." ;;
esac

stored_id="$("$NODE" -e '
  const fs = require("fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (typeof value.id !== "string") process.exit(1);
  process.stdout.write(value.id);
' "$SOURCE/theme.json")" || fail "Could not validate custom theme metadata."
[ "$stored_id" = "$THEME_ID" ] || fail "Custom theme id does not match its directory."

if [ -f "$THEME_DIR/theme.json" ]; then
  active_id="$("$NODE" -e '
    try {
      const value = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      process.stdout.write(typeof value.id === "string" ? value.id : "");
    } catch {}
  ' "$THEME_DIR/theme.json")"
  [ "$active_id" != "$THEME_ID" ] || fail "Switch to another theme before deleting the active theme."
fi

trash="$STATE_ROOT/.deleted-theme.$$.tmp"
[ ! -e "$trash" ] || fail "Temporary delete path already exists."
/bin/mv "$SOURCE" "$trash"
/bin/rm -rf "$trash"
printf 'Deleted custom theme: %s\n' "$THEME_ID"
