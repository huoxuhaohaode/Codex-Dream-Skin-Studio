#!/bin/bash

set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd -P)/common-macos.sh"

COMMUNITY_ID=""
APPLY_NOW="true"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --id) COMMUNITY_ID="${2:-}"; shift 2 ;;
    --no-apply) APPLY_NOW="false"; shift ;;
    *) fail "Unknown community-theme argument: $1" ;;
  esac
done
case "$COMMUNITY_ID" in ''|*[!a-z0-9-]*) fail "Community theme id is invalid." ;; esac

ensure_state_root
ensure_node_runtime
THEMES_ROOT="$STATE_ROOT/themes"
/bin/mkdir -p "$THEMES_ROOT"
result="$("$NODE" "$SCRIPT_DIR/community-theme.mjs" \
  --id "$COMMUNITY_ID" \
  --catalog "$PROJECT_ROOT/community/catalog.json" \
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
')" || fail "Community theme returned an invalid id."

if [ "$APPLY_NOW" = "true" ]; then
  "$SCRIPT_DIR/switch-theme-macos.sh" --id "$theme_id"
fi
printf '%s\n' "$result"
