#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

device_ids() {
  xcrun simctl list devices -j | jq -r '.devices[][] | .udid' | sort
}

before_ids="$(device_ids)"
owned_id=""
cleanup() {
  [[ -z "$owned_id" ]] && return
  xcrun simctl shutdown "$owned_id" >/dev/null 2>&1 || true
  xcrun simctl delete "$owned_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for signal_name in INT TERM; do
  log_file="$(mktemp)"
  run_id="$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c 1-24)"
  device_prefix="putio-harness-ios-$run_id-"
  ./scripts/harness.sh boot --platform ios --run-id "$run_id" >"$log_file" 2>&1 &
  harness_pid=$!
  owned_id=""

  for _ in {1..200}; do
    owned_id="$(xcrun simctl list devices -j | jq -r --arg prefix "$device_prefix" \
      '[.devices[][] | select(.name | startswith($prefix))] | if length == 1 then .[0].udid else empty end')"
    [[ -n "$owned_id" ]] && break
    sleep 0.05
  done

  if [[ -z "$owned_id" ]]; then
    kill "$harness_pid" >/dev/null 2>&1 || true
    wait "$harness_pid" >/dev/null 2>&1 || true
    cat "$log_file" >&2
    exit 1
  fi
  kill -"$signal_name" "$harness_pid"
  set +e
  wait "$harness_pid"
  status=$?
  set -e
  expected_status=130
  [[ "$signal_name" == TERM ]] && expected_status=143
  if [[ "$status" -ne "$expected_status" ]]; then
    cat "$log_file" >&2
    printf '%s interruption exited %s, expected %s\n' \
      "$signal_name" "$status" "$expected_status" >&2
    exit 1
  fi
  if device_ids | grep -Fxq "$owned_id"; then
    printf 'owned Simulator %s remains after %s\n' "$owned_id" "$signal_name" >&2
    exit 1
  fi
  owned_id=""
  rm -f "$log_file"
done

missing_ids="$(comm -23 <(printf '%s\n' "$before_ids") <(device_ids))"
[[ -z "$missing_ids" ]]
printf 'SIGINT and SIGTERM cleanup preserved the preexisting Simulator set\n'
