#!/usr/bin/env bash
set -euo pipefail

derived_data="build/release-launch/DerivedData"
app="$derived_data/Build/Products/Release-iphonesimulator/Putio.app"

device_id="$(./scripts/simctl-ephemeral-device.sh --label release-launch --no-boot)"
trap 'xcrun simctl delete "$device_id" >/dev/null 2>&1 || true' EXIT
./scripts/simctl-ephemeral-device.sh --boot "$device_id" &
boot_pid=$!

xcodebuild -workspace Putio.xcworkspace -scheme Putio -configuration Release \
  -destination "platform=iOS Simulator,id=$device_id" -derivedDataPath "$derived_data" -quiet build
./scripts/check-embedded-frameworks.sh "$app"
wait "$boot_pid"

bundle_id="$(plutil -extract CFBundleIdentifier raw "$app/Info.plist")"
xcrun simctl install "$device_id" "$app"
xcrun simctl launch "$device_id" "$bundle_id" >/dev/null
sleep 5

if ! xcrun simctl spawn "$device_id" launchctl list |
  awk -v label="UIKitApplication:$bundle_id" 'index($3, label) == 1 && $1 ~ /^[0-9]+$/ { found = 1 } END { exit !found }'; then
  echo "The Release build of $bundle_id is not running 5 seconds after launch" >&2
  exit 1
fi
echo "The Release build of $bundle_id launched and kept running"
