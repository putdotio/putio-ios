#!/bin/sh

# Create a uniquely named ephemeral simulator on the device and iOS major that
# the baselines are recorded on, and print the new device id.
# Callers own deletion (xcrun simctl delete <id>), so parallel worktrees and
# agents never share a simulator.
#
# --device-type overrides the device while keeping the runtime, so the iPad
# store-capture lane pins one runtime with everything else.

set -eu

label="ephemeral"
device_type_override=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --label)
      [ "$#" -ge 2 ] || { echo "--label needs a value" >&2; exit 2; }
      label="$2"
      shift 2
      ;;
    --device-type)
      [ "$#" -ge 2 ] || { echo "--device-type needs a simulator device type identifier" >&2; exit 2; }
      device_type_override="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

device_type="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"
ios_major="27"

runtime="$(xcrun simctl list -j runtimes | ruby -rjson -e '
  major = ARGV[0]
  runtimes = JSON.parse($stdin.read)["runtimes"].select do |runtime|
    runtime["isAvailable"] && runtime["platform"] == "iOS" && runtime["version"].split(".").first == major
  end
  newest = runtimes.max_by { |runtime| Gem::Version.new(runtime["version"]) }
  puts newest["identifier"] if newest
' "$ios_major")"

if [ -z "$runtime" ]; then
  echo "Baselines are recorded on iOS $ios_major, and no iOS $ios_major simulator runtime is installed. Run 'mise run download-ios-platform'." >&2
  exit 1
fi

if [ -n "$device_type_override" ]; then
  # simctl create accepts an unknown identifier only to fail with a bare "Invalid
  # device type", so name the typo here instead.
  xcrun simctl list -j devicetypes | ruby -rjson -e '
    target = ARGV[0]
    types = JSON.parse($stdin.read)["devicetypes"]
    exit if types.any? { |type| type["identifier"] == target }
    warn "No such simulator device type: #{target}"
    warn "Available iPad types:"
    types.select { |type| type["identifier"].include?("iPad") }
         .each { |type| warn "  #{type["identifier"]}" }
    exit 1
  ' "$device_type_override" || exit 1

  device_type="$device_type_override"
fi

device_name="putio-$label-$(date +%Y%m%d%H%M%S)-$$"

attempt=1
until device_id="$(xcrun simctl create "$device_name" "$device_type" "$runtime")"; do
    [ "$attempt" -lt 6 ] || exit 1
    echo "simctl create failed on attempt $attempt; retrying in 15s while $runtime finishes mounting" >&2
    attempt=$((attempt + 1))
    sleep 15
done

# Callers can only clean up a device whose id they were given, so anything that
# fails between here and the final echo has to delete it itself.
trap 'status=$?; if [ "$status" -ne 0 ]; then xcrun simctl delete "$device_id" >/dev/null 2>&1 || true; fi; exit "$status"' EXIT

# A new device inherits the host Mac's region, and the region decides how the
# pinned clock renders: a 24-hour host shows "09:41" where a 12-hour host shows
# "9:41". That is enough pixel drift to fail a baseline recorded on the other
# machine, so pin the locale before first boot.
data_path="$(xcrun simctl list -j devices | ruby -rjson -e '
  target = ARGV[0]
  JSON.parse($stdin.read)["devices"].each_value do |devices|
    devices.each do |device|
      if device["udid"] == target
        puts device["dataPath"]
        exit
      end
    end
  end
  abort "no device with udid #{target}"
' "$device_id")"

if [ -z "$data_path" ] || [ ! -d "$data_path" ]; then
  echo "Created device $device_id has no data directory; refusing to guess a preferences path." >&2
  exit 1
fi

global_preferences="$data_path/Library/Preferences/.GlobalPreferences.plist"
mkdir -p "$(dirname "$global_preferences")"
[ -f "$global_preferences" ] || plutil -create xml1 "$global_preferences"
plutil -replace AppleLocale -string "en_US" "$global_preferences"
plutil -replace AppleLanguages -json '["en-US"]' "$global_preferences"
plutil -replace AppleICUForce24HourTime -bool false "$global_preferences"

# Boot and pin the status bar so screenshots are deterministic for
# snapshot baselines (fixed clock, full battery and signal).
xcrun simctl bootstatus "$device_id" -b >/dev/null
xcrun simctl status_bar "$device_id" override \
  --time "9:41" \
  --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 --operatorName "" >&2

echo "$device_id"
