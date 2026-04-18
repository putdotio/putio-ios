#!/bin/sh

set -eu

workspace="Putio.xcworkspace"
scheme="Putio"
configuration="Debug"
minimum_os="26.0"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace)
      workspace="$2"
      shift 2
      ;;
    --scheme)
      scheme="$2"
      shift 2
      ;;
    --configuration)
      configuration="$2"
      shift 2
      ;;
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

build_settings="$(
  xcodebuild -showBuildSettings -workspace "$workspace" -scheme "$scheme" -configuration "$configuration" -sdk iphonesimulator 2>/dev/null
)"

target_build_dir="$(printf '%s\n' "$build_settings" | awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR = / { print $2; exit }')"
full_product_name="$(printf '%s\n' "$build_settings" | awk -F ' = ' '/^[[:space:]]*FULL_PRODUCT_NAME = / { print $2; exit }')"
bundle_identifier="$(printf '%s\n' "$build_settings" | awk -F ' = ' '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = / { print $2; exit }')"

if [ -z "$target_build_dir" ] || [ -z "$full_product_name" ] || [ -z "$bundle_identifier" ]; then
  echo "Unable to resolve simulator build settings for $scheme" >&2
  exit 1
fi

app_path="$target_build_dir/$full_product_name"
device_id="$(./scripts/simctl-iphone-device-id.sh --minimum-os "$minimum_os")"

echo "Building $scheme for iphonesimulator"
xcodebuild -workspace "$workspace" -scheme "$scheme" -configuration "$configuration" -sdk iphonesimulator build CODE_SIGNING_ALLOWED=NO >/dev/null

echo "Booting simulator: $device_id"
xcrun simctl boot "$device_id" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$device_id" -b >/dev/null

echo "Installing app: $app_path"
xcrun simctl install "$device_id" "$app_path" >/dev/null

echo "Launching app: $bundle_identifier"
xcrun simctl launch "$device_id" "$bundle_identifier"
