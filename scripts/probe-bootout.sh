#!/usr/bin/env bash
# Experiment only: compare clones left alone after boot with clones whose unneeded jobs are booted out.
set -uo pipefail
jobs=${JOBS_FILE:?}
temp=${RUNNER_TEMP:-$(mktemp -d)}
template=$(xcrun simctl list devices -j | jq -r '.devices[][] | select(.name | startswith("putio-template-")) | .udid' | head -1)
if [[ -z "$template" ]]; then
  rt=$(xcrun simctl list runtimes -j | jq -r '[.runtimes[] | select(.platform=="iOS" and .isAvailable)] | last | .identifier')
  dt=$(xcrun simctl list runtimes -j | jq -r --arg rt "$rt" '.runtimes[] | select(.identifier==$rt) | [.supportedDeviceTypes[] | select(.productFamily=="iPhone")][0].identifier')
  template=$(xcrun simctl create putio-template-probe "$dt" "$rt"); xcrun simctl boot "$template"
  xcrun simctl bootstatus "$template" -b >/dev/null 2>&1; xcrun simctl shutdown "$template"; created=1
fi
echo "template $template"
idle() { top -l "$1" -n 0 -s 10 | grep "CPU usage" | tail -n +2 | awk '{ gsub("%", "", $7); printf "%s ", int($7) }'; }
probe() {
  local c s b out; c=$(xcrun simctl clone "$template" "probe-$1"); s=$SECONDS
  xcrun simctl boot "$c"; xcrun simctl bootstatus "$c" -b >/dev/null 2>&1; b=$((SECONDS - s))
  out=""
  if [[ "$2" == bootout ]]; then
    local root paths=() t=$SECONDS
    root=$(xcrun simctl getenv "$c" SIMULATOR_ROOT)
    while read -r l; do
      for dir in System/Library/LaunchDaemons System/Library/LaunchAgents; do
        if [[ -f "$root/$dir/$l.plist" ]]; then paths+=("$root/$dir/$l.plist"); break; fi
      done
    done <"$jobs"
    xcrun simctl spawn "$c" launchctl bootout system "${paths[@]}" >/dev/null 2>&1
    out=", booted out ${#paths[@]} in $((SECONDS - t))s"
  fi
  echo "$1: boot ${b}s$out, idle% per 10s: $(idle "${SAMPLES:-13}")"
  xcrun simctl spawn "$c" launchctl list | awk '$1 ~ /^[0-9]+$/ { print $1 }' >"$temp/pids"
  echo "$1: running jobs $(grep -c . "$temp/pids"), sim CPU-s $(ps -A -o pid=,time= | awk 'NR == FNR { p[$1]; next } ($1 in p) { n = split($2, t, ":"); s += n == 3 ? t[1] * 3600 + t[2] * 60 + t[3] : t[1] * 60 + t[2] } END { printf "%.0f", s }' "$temp/pids" -)"
  xcrun simctl shutdown "$c"; xcrun simctl delete "$c"; sleep "${PAUSE:-60}"
}
for i in 1 2; do probe "stock-$i" stock; probe "bootout-$i" bootout; done
if [[ -n "${created:-}" ]]; then xcrun simctl delete "$template"; fi
