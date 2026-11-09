#!/usr/bin/env bash
set -euo pipefail

app="${1:?usage: scripts/check-embedded-frameworks.sh <app-path>}"
binary="$app/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"

missing=0
while IFS= read -r framework; do
  if [ ! -e "$app/Frameworks/$framework" ]; then
    echo "$app links @rpath/$framework but does not embed it" >&2
    missing=1
  fi
done < <(otool -L "$binary" | awk '$1 ~ /^@rpath\// { sub("^@rpath/", "", $1); print $1 }' | sort -u)

exit "$missing"
