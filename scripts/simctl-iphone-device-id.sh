#!/bin/sh

set -eu

# Baselines are pixel-compared, so the device model has to be pinned. Picking
# "whichever iPhone is listed first on the newest runtime" made baseline
# dimensions depend on which simulators a machine happened to have installed.
#
# iPhone 17 Pro Max is 1320x2868, which is also Apple's required 6.9" App Store
# screenshot size, so the store capture lane can reuse this device.
device_name="iPhone 17 Pro Max"
minimum_os="26.0"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --minimum-os)
      minimum_os="$2"
      shift 2
      ;;
    --device-name)
      device_name="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

device_id="$(xcrun simctl list devices available | awk -v minimum_os="$minimum_os" -v want="$device_name" '
function version_gte(current, minimum) {
  split(current, current_parts, ".")
  split(minimum, minimum_parts, ".")

  for (part = 1; part <= 3; part++) {
    if ((current_parts[part] + 0) > (minimum_parts[part] + 0)) {
      return 1
    }

    if ((current_parts[part] + 0) < (minimum_parts[part] + 0)) {
      return 0
    }
  }

  return 1
}

function version_gt(current, candidate) {
  if (candidate == "") {
    return 1
  }

  split(current, current_parts, ".")
  split(candidate, candidate_parts, ".")

  for (part = 1; part <= 3; part++) {
    if ((current_parts[part] + 0) > (candidate_parts[part] + 0)) {
      return 1
    }

    if ((current_parts[part] + 0) < (candidate_parts[part] + 0)) {
      return 0
    }
  }

  return 0
}

/^-- iOS / {
  current_os = $3
  sub(/ --$/, "", current_os)
  next
}

{
  if (current_os == "" || !version_gte(current_os, minimum_os)) {
    next
  }

  # Match the name exactly up to the " (UDID)" suffix, so "iPhone 17 Pro" can
  # never match the line for "iPhone 17 Pro Max".
  line = $0
  sub(/^[[:space:]]+/, "", line)
  if (index(line, want " (") != 1) {
    next
  }

  if (match($0, /\(([0-9A-F-]+)\)/)) {
    if (version_gt(current_os, best_os)) {
      found = 1
      best_os = current_os
      best_id = substr($0, RSTART + 1, RLENGTH - 2)
    }
  }
}

END {
  if (found) {
    print best_id
    exit 0
  }

  exit 1
}
')" || {
  echo "No available \"$device_name\" simulator on iOS $minimum_os or newer." >&2
  echo "Baselines are pinned to this device: create it in Xcode, or run 'mise run download-ios-platform'." >&2
  echo "Pass --device-name only when you do not intend to record baselines." >&2
  exit 1
}

printf '%s\n' "$device_id"
