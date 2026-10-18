#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

derived_data=build/DeadCode/DerivedData

./scripts/generate.sh

# Periphery cannot pick a destination per scheme, so build the index here.
# Test schemes are included so test-only callers count as uses; the Putio and
# PutioTV schemes also build their snapshot and UI test targets.
for scheme_platform in Putio:iOS PutioFeatureTests:iOS PutioTV:tvOS PutioTVFeatureTests:tvOS; do
  xcodebuild build-for-testing -quiet \
    -workspace Putio.xcworkspace \
    -scheme "${scheme_platform%%:*}" \
    -destination "generic/platform=${scheme_platform#*:} Simulator" \
    -derivedDataPath "$derived_data" \
    'ARCHS=$(NATIVE_ARCH_ACTUAL)' \
    COMPILER_INDEX_STORE_ENABLE=YES \
    CODE_SIGNING_ALLOWED=NO
done
# PutioCore's own tests are SwiftPM-only; index them so their callers count.
# SwiftPM's default build system writes no index store unless asked.
swift build --build-tests --enable-index-store \
  --package-path Packages/PutioCore --scratch-path build/DeadCode/PutioCore
swift build --build-tests --enable-index-store \
  --package-path Tools/PutioHarness --scratch-path build/DeadCode/PutioHarness

periphery scan --skip-build \
  --index-store-path "$derived_data/Index.noindex/DataStore" \
  --index-store-path build/DeadCode/PutioCore/debug/index/store \
  "$@"
# The harness is its own SwiftPM package with no Xcode project, so it gets
# the same retention flags here instead of a second config.
(
  cd Tools/PutioHarness
  periphery scan --skip-build \
    --index-store-path "$repo_root/build/DeadCode/PutioHarness/debug/index/store" \
    --retain-codable-properties \
    --retain-equatable-properties \
    --disable-redundant-public-analysis \
    --relative-results \
    "$@"
)
