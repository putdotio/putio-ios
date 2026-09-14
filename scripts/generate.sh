#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

pnpm run fonts:check
# Tuist 4.203.4 swifterpm fails to load the local GoogleCastSDK manifest.
TUIST_USE_SWIFTERPM=0 tuist install
tuist generate --no-open
