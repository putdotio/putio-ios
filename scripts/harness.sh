#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# CI restores a prebuilt binary keyed on the harness sources.
if [[ -n "${PUTIO_HARNESS_BINARY:-}" ]]; then
  exec "$PUTIO_HARNESS_BINARY" "$@"
fi
exec swift run --quiet --package-path Tools/PutioHarness putio-harness "$@"
