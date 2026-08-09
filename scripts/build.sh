#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

derived_data="$repo_root/build/DerivedData"

xcodebuild build -workspace Putio.xcworkspace -scheme Putio -destination "generic/platform=iOS Simulator" -derivedDataPath "$derived_data"
xcodebuild build -workspace Putio.xcworkspace -scheme PutioWatch -destination "generic/platform=watchOS Simulator" -derivedDataPath "$derived_data"
xcodebuild build -workspace Putio.xcworkspace -scheme PutioTV -destination "generic/platform=tvOS Simulator" -derivedDataPath "$derived_data"
