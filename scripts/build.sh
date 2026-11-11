#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Debug shells compile in the iOS and tvOS test lanes. Compile
# every shell's Release branches here; Putio builds its embedded watch app. This
# checks that non-Debug code compiles, so one architecture and no optimizer are
# enough; archives optimize.
for scheme_platform in Putio:iOS PutioNightly:iOS PutioTV:tvOS; do
  started=$SECONDS
  xcodebuild build -quiet \
    -workspace Putio.xcworkspace \
    -scheme "${scheme_platform%%:*}" \
    -configuration Release \
    -destination "generic/platform=${scheme_platform#*:} Simulator" \
    -derivedDataPath build/DerivedData \
    'ARCHS=$(NATIVE_ARCH_ACTUAL)' \
    SWIFT_OPTIMIZATION_LEVEL=-Onone \
    SWIFT_COMPILATION_MODE=singlefile \
    CODE_SIGNING_ALLOWED=NO
  printf 'build: %s Release took %ss\n' "${scheme_platform%%:*}" "$((SECONDS - started))"
done
