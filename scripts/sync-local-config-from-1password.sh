#!/bin/bash

set -euo pipefail

vault="${PUTIO_1PASSWORD_VAULT:-}"
item="${PUTIO_1PASSWORD_ITEM:-}"
template="Config/Local.1password.xcconfig.template"
output="Config/Local.xcconfig"

usage() {
  cat <<'EOF' >&2
Usage: scripts/sync-local-config-from-1password.sh --vault <vault> --item <item> [--template <path>] [--output <path>]
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
    --template)
      template="$2"
      shift 2
      ;;
    --output)
      output="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

if [[ -z "$vault" || -z "$item" ]]; then
  usage
fi

if ! command -v op >/dev/null 2>&1; then
  echo "1Password CLI 'op' is required" >&2
  exit 1
fi

if ! op whoami >/dev/null 2>&1; then
  echo "1Password CLI is not signed in. Unlock 1Password or run 'op signin' first" >&2
  exit 1
fi

mkdir -p "$(dirname "$output")"

PUTIO_1PASSWORD_VAULT="$vault" \
PUTIO_1PASSWORD_ITEM="$item" \
op inject --in-file "$template" --out-file "$output" --force --file-mode 0600

echo "Wrote $output from 1Password item '$item' in vault '$vault'"
