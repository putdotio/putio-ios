#!/bin/sh
# The verify-fast gate, minus the three sync --check passes, which mise.toml
# declares as task dependencies.

set -eu

# shellcheck disable=SC1007  # CDPATH= is a prefix assignment for cd, not an empty var
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# The brand faces are licensed; their absence from git is the compliance, so it
# is asserted rather than left to .gitignore.
if git ls-files | grep -iE '\.(otf|ttf|ttc)$'; then
    echo "verify-fast: licensed font binaries must never be committed (see CONTRIBUTING.md)." >&2
    exit 1
fi

plutil -lint Putio/en.lproj/*.strings
xcodebuild -list -workspace Putio.xcworkspace
