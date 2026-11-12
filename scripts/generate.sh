#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Download missing brand fonts; offline, generate still works with system fonts.
if ! pnpm run fonts:setup; then
  echo "Brand fonts unavailable; generating with system fonts." >&2
  pnpm run fonts:check
fi
# CI sets this when it restored Tuist/.build for exactly these manifests.
if [[ "${PUTIO_TUIST_DEPENDENCIES_CACHED:-}" != "1" ]]; then
  # Tuist 4.203.4 swifterpm fails to load the local GoogleCastSDK manifest.
  TUIST_USE_SWIFTERPM=0 tuist install
fi
node scripts/open-source-licenses.ts
tuist generate --no-open
