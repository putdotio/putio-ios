#!/usr/bin/env bash
# Archives the App Store build and exports a signed IPA for asc to upload.
# CI-only: needs the identity and profile `fastlane signing` installs, and the
# PUTIO_* build settings the release Environment provides.
#
#   scripts/archive-ios.sh <marketing-version> <build-number> <ipa-path>
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: scripts/archive-ios.sh <marketing-version> <build-number> <ipa-path>" >&2
  exit 64
fi
version="$1"
build_number="$2"
ipa_path="$3"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "marketing version must look like 3.0.0" >&2; exit 64; }
[[ "$build_number" =~ ^[0-9]+$ ]] || { echo "build number must be an integer" >&2; exit 64; }

: "${PUTIO_APP_IDENTIFIER:?}" "${PUTIO_DEVELOPMENT_TEAM:?}" "${PUTIO_PRIMARY_APP_ICON:?}"
profile="match AppStore $PUTIO_APP_IDENTIFIER"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Command-line build settings override the xcconfig defaults, which a plain
# environment variable would not. Empty values are skipped.
settings=(
  "MARKETING_VERSION=$version"
  "CURRENT_PROJECT_VERSION=$build_number"
  "CODE_SIGN_STYLE=Manual"
  "CODE_SIGN_IDENTITY=Apple Distribution"
  "PROVISIONING_PROFILE_SPECIFIER=$profile"
)
for name in PUTIO_APP_IDENTIFIER PUTIO_PRIMARY_APP_ICON PUTIO_DEVELOPMENT_TEAM PUTIO_OAUTH_CLIENT_ID \
  PUTIO_CHROMECAST_RECEIVER_APP_ID PUTIO_INTERCOM_API_KEY PUTIO_INTERCOM_APP_ID PUTIO_SENTRY_DSN; do
  if [ -n "${!name:-}" ]; then settings+=("$name=${!name}"); fi
done

cat > "$work/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>teamID</key>
  <string>$PUTIO_DEVELOPMENT_TEAM</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>$PUTIO_APP_IDENTIFIER</key>
    <string>$profile</string>
  </dict>
</dict>
</plist>
PLIST
plutil -lint "$work/ExportOptions.plist" >/dev/null

xcodebuild -workspace Putio.xcworkspace -scheme Putio -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -quiet -archivePath "$work/Putio.xcarchive" \
  "${settings[@]}" archive
xcodebuild -exportArchive -archivePath "$work/Putio.xcarchive" \
  -exportOptionsPlist "$work/ExportOptions.plist" -exportPath "$work/export" -quiet

shopt -s nullglob
ipas=("$work"/export/*.ipa)
[ "${#ipas[@]}" -eq 1 ] || { echo "expected one exported IPA, found ${#ipas[@]}" >&2; exit 1; }
mkdir -p "$(dirname "$ipa_path")"
cp "${ipas[0]}" "$ipa_path"
echo "archived $version ($build_number) to $ipa_path"
