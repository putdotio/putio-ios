#!/usr/bin/env bash
# Experiment only: compare clones of a template shut down right after boot with one left to settle.
set -uo pipefail
rt=$(xcrun simctl list runtimes -j | jq -r '[.runtimes[] | select(.platform=="iOS" and .isAvailable)] | last | .identifier')
dt=$(xcrun simctl list runtimes -j | jq -r --arg rt "$rt" '.runtimes[] | select(.identifier==$rt) | [.supportedDeviceTypes[] | select(.productFamily=="iPhone")][0].identifier')
echo "runtime $rt device $dt"
idle() { top -l "$1" -n 0 -s 10 | grep "CPU usage" | tail -n +2 | awk '{ gsub("%", "", $7); printf "%s ", int($7) }'; }
make() {
  local t s; t=$(xcrun simctl create "probe-template-$1" "$dt" "$rt"); s=$SECONDS
  xcrun simctl boot "$t"; xcrun simctl bootstatus "$t" -b >/dev/null 2>&1
  echo "template $1: boot $((SECONDS - s))s" >&2
  if [[ "$2" -gt 0 ]]; then echo "template $1: idle% per 10s while settling: $(idle "$2")" >&2; fi
  s=$SECONDS; xcrun simctl shutdown "$t"; echo "template $1: shutdown $((SECONDS - s))s" >&2
  echo "$t"
}
probe() {
  local c s b cpu; c=$(xcrun simctl clone "$2" "probe-$1"); s=$SECONDS
  xcrun simctl boot "$c"; xcrun simctl bootstatus "$c" -b >/dev/null 2>&1; b=$((SECONDS - s))
  echo "$1: boot ${b}s, load $(sysctl -n vm.loadavg), idle% per 10s: $(idle 13)"
  xcrun simctl spawn "$c" launchctl list | awk '$1 ~ /^[0-9]+$/ { print $1 }' >"$RUNNER_TEMP/pids"
  cpu=$(ps -A -o pid=,time= | awk 'NR == FNR { p[$1]; next } ($1 in p) { n = split($2, t, ":"); s += n == 3 ? t[1] * 3600 + t[2] * 60 + t[3] : t[1] * 60 + t[2] } END { printf "%.0f", s }' "$RUNNER_TEMP/pids" -)
  echo "$1: sim CPU-s over boot + 2 min: $cpu, load $(sysctl -n vm.loadavg)"
  xcrun simctl shutdown "$c"; xcrun simctl delete "$c"; sleep 20
}
quick=$(make quick 0)
settled=$(make settled 31)
for i in 1 2; do probe "quick-$i" "$quick"; probe "settled-$i" "$settled"; done
xcrun simctl delete "$quick" "$settled"
