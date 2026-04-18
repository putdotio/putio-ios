#!/bin/bash

set -euo pipefail

vault="${PUTIO_1PASSWORD_VAULT:-frontend-ci}"
item="${PUTIO_1PASSWORD_ITEM:-putio-ios}"
env_template="fastlane/.env.1password.template"
sync_local_config="true"

usage() {
  cat <<'EOF' >&2
Usage: scripts/op-fastlane.sh --vault <vault> --item <item> [--env-template <path>] [--skip-local-config-sync] <lane> [fastlane args...]
EOF
  exit 2
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --vault)
      vault="$2"
      shift 2
      ;;
    --item)
      item="$2"
      shift 2
      ;;
    --env-template)
      env_template="$2"
      shift 2
      ;;
    --skip-local-config-sync)
      sync_local_config="false"
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      ;;
    *)
      break
      ;;
  esac
done

if [[ -z "$vault" || -z "$item" || "$#" -lt 1 ]]; then
  usage
fi

if ! command -v op >/dev/null 2>&1; then
  echo "1Password CLI 'op' is required" >&2
  exit 1
fi

if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" && -n "${OP_SERVICE_ACCOUNT_PUTIO_FRONTEND_CI:-}" ]]; then
  export OP_SERVICE_ACCOUNT_TOKEN="$OP_SERVICE_ACCOUNT_PUTIO_FRONTEND_CI"
fi

if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]] && ! op whoami >/dev/null 2>&1; then
  echo "1Password CLI is not signed in. Unlock 1Password or run 'op signin' first" >&2
  exit 1
fi

if [[ "$sync_local_config" == "true" ]]; then
  ./scripts/op-local-config.sh --vault "$vault" --item "$item"
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/putio-ios-fastlane.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

runner="$tmpdir/run-fastlane.sh"
cat >"$runner" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ -n "${APPSTORE_CONNECT_KEY_CONTENT:-}" ]]; then
  key_path="${OP_1PASSWORD_TEMP_DIR}/AuthKey.p8"
  printf '%s' "$APPSTORE_CONNECT_KEY_CONTENT" >"$key_path"
  chmod 600 "$key_path"
  export APPSTORE_CONNECT_KEY_FILEPATH="$key_path"
fi

unset APPSTORE_CONNECT_KEY_CONTENT

required_keys=(
  APPSTORE_CONNECT_ISSUER_ID
  APPSTORE_CONNECT_KEY_ID
  APPSTORE_CONNECT_KEY_FILEPATH
  PUTIO_APP_IDENTIFIER
  PUTIO_APPLE_ID
  PUTIO_ITC_TEAM_ID
  PUTIO_DEVELOPMENT_TEAM
  MATCH_GIT_URL
  MATCH_TYPE
  MATCH_PASSWORD
)

missing_keys=()
for key in "${required_keys[@]}"; do
  if [[ -z "${!key:-}" ]]; then
    missing_keys+=("$key")
  fi
done

if (( ${#missing_keys[@]} > 0 )); then
  printf 'Missing required 1Password-backed fastlane settings: %s\n' "${missing_keys[*]}" >&2
  exit 1
fi

exec bundle exec fastlane "$@"
EOF
chmod 700 "$runner"

PUTIO_1PASSWORD_VAULT="$vault" \
PUTIO_1PASSWORD_ITEM="$item" \
OP_1PASSWORD_TEMP_DIR="$tmpdir" \
op run --env-file="$env_template" -- "$runner" "$@"
