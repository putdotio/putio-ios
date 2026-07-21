#!/bin/sh

# Create a uniquely named ephemeral iPhone simulator matching the device type
# and runtime of the repo's preferred simulator, and print the new device id.
# Callers own deletion (xcrun simctl delete <id>), so parallel worktrees and
# agents never share a simulator.

set -eu

label="ephemeral"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --label)
      label="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

base_device_id="$("$script_dir/simctl-iphone-device-id.sh")"

if [ -z "$base_device_id" ]; then
  echo "No iPhone simulator available to mirror. Install the iOS simulator runtime or run make download-ios-platform." >&2
  exit 1
fi

device_type_and_runtime="$(xcrun simctl list -j devices available | ruby -rjson -e '
  target = ARGV[0]
  JSON.parse($stdin.read)["devices"].each do |runtime, devices|
    devices.each do |device|
      if device["udid"] == target
        puts "#{device["deviceTypeIdentifier"]} #{runtime}"
        exit
      end
    end
  end
  abort "no available device with udid #{target}"
' "$base_device_id")"

device_type="${device_type_and_runtime% *}"
runtime="${device_type_and_runtime#* }"

device_name="putio-$label-$(date +%Y%m%d%H%M%S)-$$"

device_id="$(xcrun simctl create "$device_name" "$device_type" "$runtime")"

# Boot and pin the status bar so screenshots are deterministic for
# snapshot baselines (fixed clock, full battery and signal).
xcrun simctl bootstatus "$device_id" -b >/dev/null
xcrun simctl status_bar "$device_id" override \
  --time "9:41" \
  --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 --operatorName "" >&2

echo "$device_id"
