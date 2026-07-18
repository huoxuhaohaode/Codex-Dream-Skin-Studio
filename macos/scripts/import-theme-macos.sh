#!/bin/bash

set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd -P)/common-macos.sh"

SOURCE=""
APPLY_NOW="true"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) SOURCE="${2:-}"; shift 2 ;;
    --no-apply) APPLY_NOW="false"; shift ;;
    *) fail "Unknown import argument: $1" ;;
  esac
done
[ -n "$SOURCE" ] || fail "Usage: import-theme-macos.sh --source <theme-folder-or.dreamskin>"
[ -e "$SOURCE" ] || fail "Theme source not found: $SOURCE"

ensure_state_root
ensure_node_runtime
THEMES_ROOT="$STATE_ROOT/themes"
/bin/mkdir -p "$THEMES_ROOT"

SOURCE_FOR_IMPORT="$SOURCE"
temporary=""
cleanup_import_source() {
  [ -z "$temporary" ] || /bin/rm -rf "$temporary"
}
trap cleanup_import_source EXIT
if [ -f "$SOURCE" ]; then
  case "$SOURCE" in
    *.dreamskin)
      temporary="$(/usr/bin/mktemp -d "$STATE_ROOT/.dreamskin-decode.XXXXXX")"
      "$NODE" "$SCRIPT_DIR/dreamskin-package.mjs" inspect "$SOURCE" >/dev/null \
        || fail "The .dreamskin package failed its integrity checks."
      SOURCE_FOR_IMPORT="$temporary/theme"
      "$NODE" "$SCRIPT_DIR/dreamskin-package.mjs" extract "$SOURCE" "$SOURCE_FOR_IMPORT" >/dev/null \
        || fail "The .dreamskin package could not be decoded safely."
      ;;
    *.codexskin) ;;
    *) fail "Theme files must use .dreamskin or the legacy .codexskin extension." ;;
  esac
fi

result="$("$NODE" "$SCRIPT_DIR/theme-package.mjs" import \
  --source "$SOURCE_FOR_IMPORT" \
  --themes-root "$THEMES_ROOT" \
  --state-root "$STATE_ROOT" \
  --injector "$INJECTOR" \
  --stage-theme "$SCRIPT_DIR/stage-theme.mjs")"
theme_id="$(printf '%s' "$result" | "$NODE" -e '
  let text = "";
  process.stdin.on("data", (chunk) => { text += chunk; });
  process.stdin.on("end", () => {
    const value = JSON.parse(text);
    if (!/^custom-import-[A-Za-z0-9_-]+$/.test(value.id)) process.exit(1);
    process.stdout.write(value.id);
  });
')" || fail "Imported theme id is invalid."
cleanup_import_source
temporary=""
trap - EXIT

if [ "$APPLY_NOW" = "true" ]; then
  "$SCRIPT_DIR/switch-theme-macos.sh" --id "$theme_id"
fi
printf '%s\n' "$result"
