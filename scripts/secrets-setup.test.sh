#!/usr/bin/env bash

set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/putio-ios-secrets-test.XXXXXX")"
output="build/secrets-test/Local.xcconfig"
cleanup() {
  find "$tmp_dir" \( -type f -o -type l \) -delete
  find "$tmp_dir" -depth -type d -empty -delete
  rm -f "$output"
  rmdir "$(dirname "$output")" 2>/dev/null || true
}
trap cleanup EXIT

ciphertext="$tmp_dir/payload.sops.env"
payload="$tmp_dir/payload.json"
printf 'ciphertext fixture\n' > "$ciphertext"

sops() {
  case "${1:-}" in
    filestatus)
      [ "${2:-}" = "--input-type" ]
      [ "${3:-}" = "dotenv" ]
      printf '{"encrypted":%s}\n' "${FAKE_SOPS_ENCRYPTED:-true}"
      ;;
    decrypt)
      local destination=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --output)
            shift
            destination="$1"
            ;;
        esac
        shift
      done
      [ -n "$destination" ]
      install -m 600 "$FAKE_SOPS_PAYLOAD" "$destination"
      ;;
    *)
      return 2
      ;;
  esac
}
export -f sops

write_payload() {
  printf '%s\n' "$1" > "$payload"
}

write_valid_payload() {
  write_payload '{"PUTIO_CHROMECAST_RECEIVER_APP_ID":"CC1AD845","PUTIO_DEVELOPMENT_TEAM":"A1B2C3D4E5","PUTIO_INTERCOM_API_KEY":"ios_sdk-key","PUTIO_INTERCOM_APP_ID":"app-id","PUTIO_OAUTH_CLIENT_ID":"3001","PUTIO_SENTRY_DSN":"https://public@example.com/1"}'
}

run_setup() {
  FAKE_SOPS_PAYLOAD="$payload" \
  PUTIO_IOS_SOPS_FILE="$ciphertext" \
  SECRETS_OUTPUT="$output" \
    bash ./scripts/secrets-setup.sh
}

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    printf 'FAILED: command unexpectedly succeeded\n' >&2
    exit 1
  fi
}

write_valid_payload
run_setup >/dev/null
if output_mode="$(stat -c '%a' "$output" 2>/dev/null)"; then
  :
else
  output_mode="$(stat -f '%Lp' "$output")"
fi
[ "$output_mode" = 600 ]
grep -Fx 'PUTIO_DEVELOPMENT_TEAM = A1B2C3D4E5' "$output" >/dev/null
grep -Fx 'PUTIO_OAUTH_CLIENT_ID = 3001' "$output" >/dev/null
grep -Fx 'PUTIO_CHROMECAST_RECEIVER_APP_ID = CC1AD845' "$output" >/dev/null
grep -Fx 'PUTIO_INTERCOM_API_KEY = ios_sdk-key' "$output" >/dev/null
grep -Fx 'PUTIO_INTERCOM_APP_ID = app-id' "$output" >/dev/null
expected_sentry="PUTIO_SENTRY_DSN = https:/\$()/public@example.com/1"
grep -Fx "$expected_sentry" "$output" >/dev/null
rm -f "$output"

write_payload '{"PUTIO_CHROMECAST_RECEIVER_APP_ID":"CC1AD845","PUTIO_DEVELOPMENT_TEAM":"A1B2C3D4E5","PUTIO_INTERCOM_API_KEY":"null","PUTIO_INTERCOM_APP_ID":"null","PUTIO_OAUTH_CLIENT_ID":"3001","PUTIO_SENTRY_DSN":"null"}'
run_setup >/dev/null
grep -Fx 'PUTIO_INTERCOM_API_KEY = ' "$output" >/dev/null
grep -Fx 'PUTIO_INTERCOM_APP_ID = ' "$output" >/dev/null
grep -Fx 'PUTIO_SENTRY_DSN = ' "$output" >/dev/null
rm -f "$output"

write_payload '{"PUTIO_DEVELOPMENT_TEAM":"A1B2C3D4E5"}'
expect_failure run_setup
[ ! -e "$output" ]

write_payload '{"PUTIO_CHROMECAST_RECEIVER_APP_ID":"CC1AD845","PUTIO_DEVELOPMENT_TEAM":"A1B2C3D4E5","PUTIO_INTERCOM_API_KEY":"null","PUTIO_INTERCOM_APP_ID":"null","PUTIO_OAUTH_CLIENT_ID":"3001","PUTIO_SENTRY_DSN":"null","UNEXPECTED":"value"}'
expect_failure run_setup
[ ! -e "$output" ]

write_payload '{"PUTIO_CHROMECAST_RECEIVER_APP_ID":"CC1AD845","PUTIO_DEVELOPMENT_TEAM":"A1B2C3D4E5","PUTIO_INTERCOM_API_KEY":"null","PUTIO_INTERCOM_APP_ID":"null","PUTIO_OAUTH_CLIENT_ID":"","PUTIO_SENTRY_DSN":"null"}'
expect_failure run_setup
[ ! -e "$output" ]

write_payload '{"PUTIO_CHROMECAST_RECEIVER_APP_ID":"CC1AD845","PUTIO_DEVELOPMENT_TEAM":"A1B2C3D4E5","PUTIO_INTERCOM_API_KEY":"null","PUTIO_INTERCOM_APP_ID":"null","PUTIO_OAUTH_CLIENT_ID":3001,"PUTIO_SENTRY_DSN":"null"}'
expect_failure run_setup
[ ! -e "$output" ]

write_payload '{"PUTIO_CHROMECAST_RECEIVER_APP_ID":"CC1AD845","PUTIO_DEVELOPMENT_TEAM":"short","PUTIO_INTERCOM_API_KEY":"null","PUTIO_INTERCOM_APP_ID":"null","PUTIO_OAUTH_CLIENT_ID":"3001","PUTIO_SENTRY_DSN":"null"}'
expect_failure run_setup
[ ! -e "$output" ]

write_payload '{"PUTIO_CHROMECAST_RECEIVER_APP_ID":"CC1AD845","PUTIO_DEVELOPMENT_TEAM":"A1B2C3D4E5","PUTIO_INTERCOM_API_KEY":"null","PUTIO_INTERCOM_APP_ID":"null","PUTIO_OAUTH_CLIENT_ID":"not-numeric","PUTIO_SENTRY_DSN":"null"}'
expect_failure run_setup
[ ! -e "$output" ]

write_payload '{"PUTIO_CHROMECAST_RECEIVER_APP_ID":"wrong","PUTIO_DEVELOPMENT_TEAM":"A1B2C3D4E5","PUTIO_INTERCOM_API_KEY":"null","PUTIO_INTERCOM_APP_ID":"null","PUTIO_OAUTH_CLIENT_ID":"3001","PUTIO_SENTRY_DSN":"null"}'
expect_failure run_setup
[ ! -e "$output" ]

write_payload '{"PUTIO_CHROMECAST_RECEIVER_APP_ID":"CC1AD845","PUTIO_DEVELOPMENT_TEAM":"A1B2C3D4E5","PUTIO_INTERCOM_API_KEY":"bad value","PUTIO_INTERCOM_APP_ID":"null","PUTIO_OAUTH_CLIENT_ID":"3001","PUTIO_SENTRY_DSN":"null"}'
expect_failure run_setup
[ ! -e "$output" ]

write_payload '{"PUTIO_CHROMECAST_RECEIVER_APP_ID":"CC1AD845","PUTIO_DEVELOPMENT_TEAM":"A1B2C3D4E5","PUTIO_INTERCOM_API_KEY":"null","PUTIO_INTERCOM_APP_ID":"null","PUTIO_OAUTH_CLIENT_ID":"\"3001\"","PUTIO_SENTRY_DSN":"null"}'
expect_failure run_setup
[ ! -e "$output" ]

write_payload '{"PUTIO_CHROMECAST_RECEIVER_APP_ID":"CC1AD845","PUTIO_DEVELOPMENT_TEAM":"A1B2C3D4E5","PUTIO_INTERCOM_API_KEY":"null","PUTIO_INTERCOM_APP_ID":"null","PUTIO_OAUTH_CLIENT_ID":"3001","PUTIO_SENTRY_DSN":"http://example.com/1"}'
expect_failure run_setup
[ ! -e "$output" ]

write_payload '{"PUTIO_CHROMECAST_RECEIVER_APP_ID":"CC1AD845","PUTIO_DEVELOPMENT_TEAM":"A1B2C3D4E5","PUTIO_INTERCOM_API_KEY":"line\none","PUTIO_INTERCOM_APP_ID":"null","PUTIO_OAUTH_CLIENT_ID":"3001","PUTIO_SENTRY_DSN":"null"}'
expect_failure run_setup
[ ! -e "$output" ]

write_valid_payload
expect_failure env \
  FAKE_SOPS_ENCRYPTED=false \
  FAKE_SOPS_PAYLOAD="$payload" \
  PUTIO_IOS_SOPS_FILE="$ciphertext" \
  SECRETS_OUTPUT="$output" \
  bash ./scripts/secrets-setup.sh
[ ! -e "$output" ]

expect_failure env \
  FAKE_SOPS_PAYLOAD="$payload" \
  PUTIO_IOS_SOPS_FILE="$ciphertext" \
  SECRETS_OUTPUT=README.md \
  bash ./scripts/secrets-setup.sh

expect_failure env \
  FAKE_SOPS_PAYLOAD="$payload" \
  PUTIO_IOS_SOPS_FILE="$ciphertext" \
  SECRETS_OUTPUT= \
  bash ./scripts/secrets-setup.sh

symlinked_ciphertext="$tmp_dir/symlinked.sops.env"
ln -s "$ciphertext" "$symlinked_ciphertext"
expect_failure env \
  FAKE_SOPS_PAYLOAD="$payload" \
  PUTIO_IOS_SOPS_FILE="$symlinked_ciphertext" \
  SECRETS_OUTPUT="$output" \
  bash ./scripts/secrets-setup.sh

mkdir -p "$(dirname "$output")"
ln -s "$tmp_dir/redirected.xcconfig" "$output"
expect_failure run_setup
rm -f "$output"

symlinked_parent="build/secrets-parent.$$"
mkdir -p "$tmp_dir/outside"
ln -s "$tmp_dir/outside" "$symlinked_parent"
expect_failure env \
  FAKE_SOPS_PAYLOAD="$payload" \
  PUTIO_IOS_SOPS_FILE="$ciphertext" \
  SECRETS_OUTPUT="$symlinked_parent/Local.xcconfig" \
  bash ./scripts/secrets-setup.sh
rm -f "$symlinked_parent"

printf 'ok SOPS setup renders validated ignored xcconfig and fails closed\n'
