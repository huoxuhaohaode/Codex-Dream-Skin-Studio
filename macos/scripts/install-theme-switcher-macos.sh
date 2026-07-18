#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DESTINATION="$HOME/Applications/Codex Dream Skin Switcher.app"
OPEN_AFTER_INSTALL="true"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-open) OPEN_AFTER_INSTALL="false"; shift ;;
    --destination) DESTINATION="${2:-}"; shift 2 ;;
    *) printf 'Unknown installer argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[ -x "$ROOT/scripts/switch-theme-macos.sh" ] \
  || { printf 'Dream Skin engine scripts are missing.\n' >&2; exit 1; }

temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dream-skin-switcher.XXXXXX")"
build="$temporary/Codex Dream Skin Switcher.app"
stage="$DESTINATION.installing.$$"
previous="$DESTINATION.previous.$$"
cleanup() { /bin/rm -rf "$temporary" "$stage"; }
trap cleanup EXIT

"$ROOT/scripts/build-theme-switcher-macos.sh" "$build"
/bin/mkdir -p "$(dirname "$DESTINATION")"
/usr/bin/rsync -a "$build/" "$stage/"

destination_executable="$DESTINATION/Contents/MacOS/DreamSkinSwitcher"
destination_pids() {
  local pid command
  while read -r pid command; do
    [ "$command" = "$destination_executable" ] && printf '%s\n' "$pid"
  done < <(/bin/ps -axo pid=,command=)
}

if [ -e "$DESTINATION" ] && [ -n "$(destination_pids)" ]; then
  /usr/bin/osascript -e 'tell application id "com.codexdreamskin.switcher" to quit' \
    >/dev/null 2>&1 || true
  deadline=$((SECONDS + 5))
  while [ -n "$(destination_pids)" ] && [ "$SECONDS" -lt "$deadline" ]; do
    /bin/sleep 0.2
  done
  if [ -n "$(destination_pids)" ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] && /bin/kill -TERM "$pid" 2>/dev/null || true
    done < <(destination_pids)
    /bin/sleep 0.5
  fi
  [ -z "$(destination_pids)" ] \
    || { printf 'Could not stop the existing theme switcher safely.\n' >&2; exit 1; }
fi

if [ -e "$DESTINATION" ]; then
  /bin/mv "$DESTINATION" "$previous"
fi
if ! /bin/mv "$stage" "$DESTINATION"; then
  [ -e "$previous" ] && /bin/mv "$previous" "$DESTINATION"
  printf 'Could not install %s\n' "$DESTINATION" >&2
  exit 1
fi
/bin/rm -rf "$previous"
trap - EXIT
/bin/rm -rf "$temporary"

/usr/bin/touch "$DESTINATION"
launch_services_register="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$launch_services_register" ]; then
  "$launch_services_register" -f "$DESTINATION" >/dev/null 2>&1 || true
fi

printf 'Installed %s\n' "$DESTINATION"
if [ "$OPEN_AFTER_INSTALL" = "true" ]; then
  /usr/bin/open -n "$DESTINATION"
fi
