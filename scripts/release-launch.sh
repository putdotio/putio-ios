#!/usr/bin/env bash
set -euo pipefail

derived_data="build/release-launch/DerivedData"
app="$derived_data/Build/Products/Release-iphonesimulator/Putio.app"
launch_log="build/release-launch/launch-stderr.log"

device_id="$(./scripts/simctl-ephemeral-device.sh --label release-launch --no-boot)"
trap 'xcrun simctl delete "$device_id" >/dev/null 2>&1 || true' EXIT
./scripts/simctl-ephemeral-device.sh --boot "$device_id" &
boot_pid=$!

xcodebuild -workspace Putio.xcworkspace -scheme Putio -configuration Release \
  -destination "platform=iOS Simulator,id=$device_id" -derivedDataPath "$derived_data" -quiet build
./scripts/check-embedded-frameworks.sh "$app"
for bundle in GoogleCastCoreResources GoogleCastUIResources; do
  if [ ! -d "$app/Frameworks/GoogleCast.framework/$bundle.bundle" ]; then
    echo "$app is missing GoogleCast.framework/$bundle.bundle, so the Cast UI has no icons or text" >&2
    exit 1
  fi
done
wait "$boot_pid"

bundle_id="$(plutil -extract CFBundleIdentifier raw "$app/Info.plist")"
xcrun simctl install "$device_id" "$app"
rm -f "$launch_log"
xcrun simctl launch --stderr="$PWD/$launch_log" "$device_id" "$bundle_id" >/dev/null
sleep 5

if ! xcrun simctl spawn "$device_id" launchctl list |
  awk -v label="UIKitApplication:$bundle_id" 'index($3, label) == 1 && $1 ~ /^[0-9]+$/ { found = 1 } END { exit !found }'; then
  echo "The Release build of $bundle_id is not running 5 seconds after launch" >&2
  exit 1
fi
if [ ! -f "$launch_log" ]; then
  echo "simctl wrote no launch log to $launch_log" >&2
  exit 1
fi
if grep -F "is implemented in both" "$launch_log" >&2; then
  echo "The Release build of $bundle_id loads an Objective-C class twice" >&2
  exit 1
fi
echo "The Release build of $bundle_id launched and kept running"
