#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

pnpm run fonts:check
# CI sets this when it restored Tuist/.build for exactly these manifests.
if [[ "${PUTIO_TUIST_DEPENDENCIES_CACHED:-}" != "1" ]]; then
  # Tuist 4.203.4 swifterpm fails to load the local GoogleCastSDK manifest.
  TUIST_USE_SWIFTERPM=0 tuist install
fi
tuist generate --no-open
