#!/usr/bin/env bash
# Maestro reports a ready Android device as "not connected" while any other row of `adb devices`
# isn't in the `device` state. Runs a trivial flow three times against one ready device:
#   1. alone                              -> passes
#   2. while another row is not `device`  -> fails with "… was requested, but it is not connected."
#   3. after that row is gone or ready    -> passes again
#
# usage: ./repro.sh --device <serial>          use a device that is already `device` in adb
#        ./repro.sh --avd <name>               boot that AVD (read-only, no window) on port 5560
#        add --boot-neighbour (needs --avd)    the other row is a second emulator booting, instead
#                                              of an adb connect to a socket that never answers
# env:   MAESTRO=<path to maestro>  (default: maestro on PATH), ANDROID_HOME / ANDROID_SDK_ROOT
#
# Exit code: 1 if the bug reproduced, 0 if step 2 passed too, 2 on a setup error.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

SERIAL="" AVD="" NEIGHBOUR=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) SERIAL="$2"; shift 2 ;;
    --avd) AVD="$2"; shift 2 ;;
    --boot-neighbour) NEIGHBOUR=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$SERIAL" || -n "$AVD" ]] || { echo "pass --device <serial> or --avd <name> (see --help)" >&2; exit 2; }
[[ $NEIGHBOUR -eq 0 || -n "$AVD" ]] || { echo "--boot-neighbour needs --avd" >&2; exit 2; }

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ADB="$SDK/platform-tools/adb"
EMULATOR="$SDK/emulator/emulator"
MAESTRO="${MAESTRO:-maestro}"
PORT_A="${PORT_A:-5560}" PORT_B="${PORT_B:-5562}" STUCK_PORT="${STUCK_PORT:-5999}"
for tool in "$ADB" "$MAESTRO" python3; do
  command -v "$tool" >/dev/null || { echo "not found: $tool" >&2; exit 2; }
done
export MAESTRO_CLI_NO_ANALYTICS=1 MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true
mkdir -p out

EMULATOR_PIDS=() LISTENER="" CONNECTED=""
cleanup() {
  set +e
  [[ -z "$CONNECTED" ]] || "$ADB" disconnect "$CONNECTED" >/dev/null 2>&1
  [[ -z "$LISTENER" ]] || { kill "$LISTENER"; wait "$LISTENER"; } 2>/dev/null
  for port in ${STARTED_PORTS:-}; do "$ADB" -s "emulator-$port" emu kill >/dev/null 2>&1; done
  for pid in ${EMULATOR_PIDS[@]+"${EMULATOR_PIDS[@]}"}; do
    for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    kill "$pid" 2>/dev/null
  done
}
trap cleanup EXIT

state_of() { "$ADB" devices | awk -v s="$1" -F'\t' '$1 == s {print $2}'; }
rows() { "$ADB" devices | awk -F'\t' 'NF == 2 {printf "%s%s=%s", sep, $1, $2; sep=", "}'; }

boot_emulator() {   # <port>: start the AVD read-only, return once the row shows up
  local port="$1"
  [[ -z "$(state_of "emulator-$port")" ]] || { echo "emulator-$port is already in use" >&2; exit 2; }
  "$EMULATOR" -avd "$AVD" -port "$port" -read-only -no-window -no-snapshot -no-audio -no-boot-anim \
    >"out/emulator-$port.log" 2>&1 &
  EMULATOR_PIDS+=($!)
  STARTED_PORTS="${STARTED_PORTS:-} $port"
  for _ in $(seq 300); do [[ -n "$(state_of "emulator-$port")" ]] && return; sleep 0.2; done
  echo "emulator-$port never showed up in adb devices, see out/emulator-$port.log" >&2; exit 2
}

wait_booted() {     # <serial>
  for _ in $(seq 300); do
    [[ "$("$ADB" -s "$1" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] && return
    sleep 1
  done
  echo "$1 did not finish booting in 5 min" >&2; exit 2
}

RESULTS=()
run_flow() {        # <step name>
  local log="out/step-${#RESULTS[@]}.log" before rc=0
  before="$(rows)"
  "$MAESTRO" --device "$SERIAL" test flows/home.yaml >"$log" 2>&1 || rc=$?
  local verdict=PASS
  if [[ $rc -ne 0 ]]; then
    verdict="FAIL: $(grep -m1 'was requested, but it is not connected' "$log" || tail -n 1 "$log")"
  fi
  RESULTS+=("$1|$before|$verdict")
  printf '  %-34s %s\n' "$1" "$verdict"
}

echo "Maestro $("$MAESTRO" --version 2>/dev/null | tail -n 1) ($MAESTRO)"
if [[ -z "$SERIAL" ]]; then
  echo "booting ${AVD} on emulator-${PORT_A}…"
  boot_emulator "$PORT_A"
  SERIAL="emulator-$PORT_A"
fi
wait_booted "$SERIAL"
[[ "$(state_of "$SERIAL")" == device ]] || { echo "$SERIAL is not in the device state" >&2; exit 2; }
echo "device under test: $SERIAL"

run_flow "1. alone"

if [[ $NEIGHBOUR -eq 1 ]]; then
  NEXT="emulator-$PORT_B"
  echo "booting a second emulator (${NEXT}); it is offline for its first seconds…"
  boot_emulator "$PORT_B"
else
  # adb lists a TCP device that never answers as `offline` until it is disconnected.
  python3 -c 'import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); held = []
while True: held.append(s.accept())' "$STUCK_PORT" &
  LISTENER=$!
  sleep 0.5
  NEXT="127.0.0.1:$STUCK_PORT"
  ("$ADB" connect "$NEXT" >/dev/null 2>&1 &)
  CONNECTED="$NEXT"
  for _ in $(seq 50); do [[ -n "$(state_of "$NEXT")" ]] && break; sleep 0.2; done
fi
[[ "$(state_of "$NEXT")" != device ]] || { echo "$NEXT was ready before step 2; run again" >&2; exit 2; }

run_flow "2. while $NEXT is $(state_of "$NEXT")"

if [[ $NEIGHBOUR -eq 1 ]]; then
  wait_booted "$NEXT"
else
  "$ADB" disconnect "$NEXT" >/dev/null 2>&1
  CONNECTED=""
fi
run_flow "3. after that row is gone or ready"

echo
echo "adb devices before each step:"
for result in "${RESULTS[@]}"; do
  IFS='|' read -r step before _ <<<"$result"
  printf '  %-34s %s\n' "$step" "$before"
done
if [[ "${RESULTS[1]##*|}" == FAIL* && "${RESULTS[0]##*|}" == PASS && "${RESULTS[2]##*|}" == PASS ]]; then
  echo "REPRODUCED: $SERIAL was ready in all three steps, but Maestro could not see it in step 2."
  exit 1
fi
echo "NOT REPRODUCED (logs in out/)"
