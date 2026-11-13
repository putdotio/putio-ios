#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: scripts/upload-dsyms.sh <dsym-dir>" >&2
  exit 64
fi
dsym_dir="$1"

fail() {
  echo "::error title=Sentry dSYM upload::$1"
  exit 1
}

[ -n "${SENTRY_AUTH_TOKEN:-}" ] || fail "SENTRY_AUTH_TOKEN is empty. Add it to the release Environment, then upload this run's dsyms artifact."
[ -d "$dsym_dir/Putio.app.dSYM" ] || fail "$dsym_dir has no Putio.app.dSYM. Check DEBUG_INFORMATION_FORMAT for Release."

args=(debug-files upload --project ios --wait-for 600)
if [ -n "${SENTRY_ORG:-}" ]; then args+=(--org "$SENTRY_ORG"); else unset SENTRY_ORG; fi
sentry-cli "${args[@]}" "$dsym_dir" || fail "sentry-cli could not upload $dsym_dir. Retry with this run's dsyms artifact."
