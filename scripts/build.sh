#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

./scripts/harness.sh build --platform all

# Harness builds are Debug; compile every shell's Release branches too. Putio
# builds its embedded watch app. One architecture is enough for this check.
for scheme_platform in Putio:iOS PutioNightly:iOS PutioTV:tvOS; do
  xcodebuild build -quiet \
    -workspace Putio.xcworkspace \
    -scheme "${scheme_platform%%:*}" \
    -configuration Release \
    -destination "generic/platform=${scheme_platform#*:} Simulator" \
    -derivedDataPath build/DerivedData \
    'ARCHS=$(NATIVE_ARCH_ACTUAL)' \
    CODE_SIGNING_ALLOWED=NO
done
