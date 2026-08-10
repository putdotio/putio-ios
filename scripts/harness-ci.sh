#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ -n "${PUTIO_HARNESS_RUN_ID:-}" ]]; then
  run_id="$PUTIO_HARNESS_RUN_ID"
elif [[ -n "${GITHUB_RUN_ID:-}" ]]; then
  run_id="ci-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}"
else
  run_id="ci-local-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
./scripts/harness.sh proof --platform ios --run-id "$run_id" --record-seconds 1 --output json
