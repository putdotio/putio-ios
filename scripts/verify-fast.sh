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

# Only the SDK may fill the event fields SentryTelemetry's allowlist keeps.
if git grep -nE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+([a-z]+[[:space:]]+)?Sentry([.[:space:]]|$)' -- 'Putio/*.swift' ':(exclude)Putio/Common/Telemetry/*'; then
    echo "verify-fast: import Sentry only in Putio/Common/Telemetry; report through SentryTelemetry." >&2
    exit 1
fi

plutil -lint Putio/en.lproj/*.strings

# en.lproj is a folder reference, copied into the app verbatim, so a build
# setting such as ${PRODUCT_NAME} in a .strings file reaches users unexpanded.
if grep -nE '\$[({]' Putio/en.lproj/*.strings; then
    echo "verify-fast: .strings files are not build-setting expanded; write the literal text." >&2
    exit 1
fi

xcodebuild -list -workspace Putio.xcworkspace
