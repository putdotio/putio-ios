#!/bin/sh

set -eu

minimum_os="26.0"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --minimum-os)
      minimum_os="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

xcrun simctl list devices available | awk -v minimum_os="$minimum_os" '
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

/^[[:space:]]+iPhone/ {
  if (!version_gte(current_os, minimum_os)) {
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
'
