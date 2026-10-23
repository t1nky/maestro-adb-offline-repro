#!/usr/bin/env bash
# No device needed: Maestro's own Android device listing, run against a stub adb server.
#
#   ./no-device/run.sh                                   # the installed Maestro (~/.maestro/lib)
#   MAESTRO_LIB=<checkout>/maestro-cli/build/install/maestro/lib ./no-device/run.sh   # a local build
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAESTRO_LIB="${MAESTRO_LIB:-$HOME/.maestro/lib}"
[[ -d "$MAESTRO_LIB" ]] || { echo "no Maestro jars in $MAESTRO_LIB (set MAESTRO_LIB)" >&2; exit 2; }
# Same Java as the maestro launcher: $JAVA_HOME first, then PATH.
JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"
"$JAVA" -version >/dev/null 2>&1 || { echo "Java 17+ is needed: set JAVA_HOME (the one Maestro runs on)" >&2; exit 2; }

PORT_FILE="$(mktemp)"
trap 'rm -f "$PORT_FILE"' EXIT
list_with() {
  local server port=""
  python3 "$HERE/fake_adb_server.py" "$@" >"$PORT_FILE" &
  server=$!
  for _ in $(seq 50); do port="$(head -n 1 "$PORT_FILE")"; [[ -n "$port" ]] && break; sleep 0.1; done
  printf '%-52s → ' "adb devices: $*"
  "$JAVA" -cp "$MAESTRO_LIB/*" "$HERE/ListDevices.java" "$port" 2>&1 | grep -v SLF4J
  kill "$server"
  wait "$server" 2>/dev/null || true
}

echo "Maestro jars: $MAESTRO_LIB"
list_with emulator-5560=device emulator-5562=device
list_with emulator-5560=device emulator-5562=offline
list_with emulator-5560=device R58N12345=unauthorized
