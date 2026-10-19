#!/usr/bin/env bash
# Installs the App Store distribution identity into a new keychain, and the
# active App Store profile check-signing-profile.rb picks for that identity and
# PUTIO_APP_IDENTIFIER. CI-only, on macOS,
# with the pinned asc on PATH. Creates and revokes nothing in App Store Connect.
#
# Reads APPLE_DISTRIBUTION_P12 (base64 PKCS#12), APPLE_DISTRIBUTION_P12_PASSWORD,
# PUTIO_APP_IDENTIFIER, PUTIO_DEVELOPMENT_TEAM, and asc's ASC_* key variables.
# Appends PUTIO_SIGNING_KEYCHAIN, PUTIO_SIGNING_CERTIFICATE_SHA1 and
# PUTIO_PROVISIONING_PROFILE_UUID to GITHUB_ENV for archive-ios.sh.
set -euo pipefail

: "${APPLE_DISTRIBUTION_P12:?}" "${APPLE_DISTRIBUTION_P12_PASSWORD:?}"
: "${PUTIO_APP_IDENTIFIER:?}" "${PUTIO_DEVELOPMENT_TEAM:?}" "${RUNNER_TEMP:?}" "${GITHUB_ENV:?}"

fail() {
  echo "install-signing: $*" >&2
  exit 1
}

umask 077
work="$(mktemp -d "$RUNNER_TEMP/signing.XXXXXX")"
trap 'rm -rf "$work"' EXIT

printf '%s' "$APPLE_DISTRIBUTION_P12" | base64 --decode > "$work/identity.p12" \
  || fail "APPLE_DISTRIBUTION_P12 is not base64"
printf '%s' "$APPLE_DISTRIBUTION_P12_PASSWORD" > "$work/identity-password"
# Only this job unlocks the keychain, so its password never leaves the run.
openssl rand -hex 32 > "$work/keychain-password"

keychain="$RUNNER_TEMP/putio-signing-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}.keychain-db"
# Exported before asc creates it, so the job's cleanup step finds a keychain
# that any later failure, asc's own included, leaves behind.
echo "PUTIO_SIGNING_KEYCHAIN=$keychain" >> "$GITHUB_ENV"
identity="$(asc signing keychain install --identity "$work/identity.p12" \
  --identity-password-file "$work/identity-password" --keychain "$keychain" \
  --keychain-password-file "$work/keychain-password" --add-to-search-list --confirm --output json)"
certificate_sha256="$(jq -er '.certificateSha256' <<< "$identity")"
certificate_sha1="$(jq -er '.certificateSha1' <<< "$identity")"
team_id="$(jq -er '.teamId' <<< "$identity")"
[ "$team_id" = "$PUTIO_DEVELOPMENT_TEAM" ] \
  || fail "the identity belongs to team $team_id, not PUTIO_DEVELOPMENT_TEAM"

# Every active App Store profile, not `asc signing fetch`: fetch takes the first
# one for the bundle ID whatever its certificate, and this one must be the
# identity's.
asc profiles list --profile-type IOS_APP_STORE --profile-state ACTIVE \
  --fields name,profileContent,uuid --paginate --output json > "$work/profiles.json"
profile="$work/App.mobileprovision"
uuid="$(ruby "$(dirname "$0")/check-signing-profile.rb" "$work/profiles.json" "$certificate_sha256" \
  "$PUTIO_APP_IDENTIFIER" "$PUTIO_DEVELOPMENT_TEAM" "$profile")"
asc profiles local install --path "$profile" --output json > /dev/null

{
  echo "PUTIO_SIGNING_CERTIFICATE_SHA1=$certificate_sha1"
  echo "PUTIO_PROVISIONING_PROFILE_UUID=$uuid"
} >> "$GITHUB_ENV"
echo "installed certificate $certificate_sha256 and profile $uuid for $PUTIO_APP_IDENTIFIER"
