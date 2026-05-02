#!/bin/bash

set -euo pipefail

vault="${PUTIO_1PASSWORD_VAULT:-}"
item="${PUTIO_1PASSWORD_ITEM:-}"
template="Config/Local.1password.xcconfig.template"
output="Config/Local.xcconfig"
op_account="putdotio.1password.com"

usage() {
  cat <<'EOF' >&2
Usage: scripts/op-local-config.sh --vault <vault> --item <item> [--template <path>] [--output <path>]

You can also set PUTIO_1PASSWORD_VAULT and PUTIO_1PASSWORD_ITEM in your local shell.
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

if ! OP_ACCOUNT="$op_account" op whoami >/dev/null 2>&1; then
  echo "1Password CLI session not found for account $op_account. Either:" >&2
  echo "  - Sign in to $op_account in the 1Password desktop app and enable CLI integration, OR" >&2
  echo "  - Export OP_SERVICE_ACCOUNT_TOKEN (shared devboxes / CI)" >&2
  exit 1
fi

mkdir -p "$(dirname "$output")"

OP_ACCOUNT="$op_account" \
PUTIO_1PASSWORD_VAULT="$vault" \
PUTIO_1PASSWORD_ITEM="$item" \
op inject --in-file "$template" --out-file "$output" --force --file-mode 0600

echo "Wrote $output from 1Password item '$item' in vault '$vault'"
