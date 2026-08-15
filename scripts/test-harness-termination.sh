#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

run_id="termination-test-${PPID}-$$"
device_prefix="putio-harness-ios-${run_id}"
owned_id=""
harness_pid=""
probe_tmp="$(mktemp -d "${TMPDIR:-/tmp}/putio-harness-termination.XXXXXX")"

device_rows() {
  local prefix="$1"
  xcrun simctl list devices -j | node -e '
    const fs = require("node:fs");
    const prefix = process.argv[1];
    const payload = JSON.parse(fs.readFileSync(0, "utf8"));
    for (const devices of Object.values(payload.devices)) {
      for (const device of devices) {
        if (device.name.startsWith(prefix)) {
          process.stdout.write(`${device.udid}\t${device.state}\t${device.name}\n`);
        }
      }
    }
  ' "$prefix"
}

device_ids() {
  xcrun simctl list devices -j | node -e '
    const fs = require("node:fs");
    const payload = JSON.parse(fs.readFileSync(0, "utf8"));
    const ids = Object.values(payload.devices).flat().map((device) => device.udid).sort();
    process.stdout.write(ids.join("\n"));
  '
}

cleanup_probe() {
  local primary_status=$?
  trap - EXIT
  if [[ -n "$harness_pid" ]] && kill -0 "$harness_pid" 2>/dev/null; then
    kill -CONT "$harness_pid" 2>/dev/null || true
    kill -TERM "$harness_pid" 2>/dev/null || true
    wait "$harness_pid" 2>/dev/null || true
  fi
  if [[ -n "$owned_id" ]] && device_rows "$device_prefix" | grep -q "^${owned_id}"; then
    xcrun simctl shutdown "$owned_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$owned_id" >/dev/null 2>&1 || true
  fi
  if [[ "$primary_status" -ne 0 ]]; then
    sed -n '1,80p' "$probe_tmp/stdout" >&2 || true
    sed -n '1,80p' "$probe_tmp/stderr" >&2 || true
  fi
  rm -rf "$probe_tmp"
  exit "$primary_status"
}
trap cleanup_probe EXIT

before_ids="$(device_ids)"
binary_directory="$(swift build --package-path Tools/PutioHarness --show-bin-path)"
/usr/bin/perl -MPOSIX -e 'POSIX::setpgid(0, 0); exec @ARGV' \
  "${binary_directory}/putio-harness" \
  boot --platform ios --run-id "$run_id" --output json \
  >"$probe_tmp/stdout" \
  2>"$probe_tmp/stderr" &
harness_pid=$!

state_at_signal=""
for _ in $(seq 1 500); do
  row="$(device_rows "$device_prefix" | head -n 1)"
  if [[ -n "$row" ]]; then
    owned_id="$(cut -f1 <<<"$row")"
    state_at_signal="$(cut -f2 <<<"$row")"
    if [[ "$state_at_signal" == "Booted" ]]; then
      kill -STOP -- "-$harness_pid"
      process_state=""
      for _ in $(seq 1 100); do
        process_state="$(ps -o state= -p "$harness_pid" | tr -d ' ')"
        if [[ "$process_state" == T* ]]; then
          break
        fi
        sleep 0.01
      done
      if [[ "$process_state" != T* ]]; then
        echo "termination test could not confirm the harness was stopped" >&2
        exit 1
      fi
      break
    fi
  fi
  if ! kill -0 "$harness_pid" 2>/dev/null; then
    break
  fi
  sleep 0.01
done

if [[ "$state_at_signal" != "Booted" ]] || ! kill -0 "$harness_pid" 2>/dev/null; then
  echo "termination test did not observe an owned Booted Simulator" >&2
  exit 1
fi

kill -TERM -- "-$harness_pid"
kill -CONT -- "-$harness_pid"
for _ in $(seq 1 100); do
  kill -TERM -- "-$harness_pid" 2>/dev/null || break
  sleep 0.01
done
set +e
wait "$harness_pid"
exit_status=$?
set -e
harness_pid=""

after_ids="$(device_ids)"
if [[ "$exit_status" -ne 143 ]]; then
  echo "termination test expected exit 143, received ${exit_status}" >&2
  exit 1
fi
if device_rows "$device_prefix" | grep -q .; then
  echo "termination test found the owned Simulator after harness exit" >&2
  exit 1
fi
if [[ "$before_ids" != "$after_ids" ]]; then
  echo "termination test changed the preexisting Simulator set" >&2
  exit 1
fi

echo "termination cleanup passed for ${owned_id}; exit=143; immediate absence confirmed"
