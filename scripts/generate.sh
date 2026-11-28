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
  if [[ -n "${CI:-}" ]] && ! git diff --quiet -- Tuist/Package.resolved; then
    echo "::error file=Tuist/Package.resolved::tuist install re-resolved packages. Run mise run bootstrap and commit Tuist/Package.resolved." >&2
    git diff --stat -- Tuist/Package.resolved >&2
    exit 1
  fi
fi
node scripts/open-source-licenses.ts
brand_fonts=""
for font in Resources/BrandFonts/*.otf; do
  if [[ -e "$font" ]]; then
    brand_fonts+="${brand_fonts:+,}${font##*/}"
  fi
done
TUIST_PUTIO_BRAND_FONTS="$brand_fonts" tuist generate --no-open
