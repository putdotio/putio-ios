#!/bin/sh
# Records snapshot baselines, then immediately asserts against what it wrote.
#
# Two tiers, because they are two schemes and two test targets:
#
#   components  scheme Putio      target PutioTests    fixed-size view snapshots
#   screens     scheme PutioE2E   target PutioUITests  full-screen walk captures
#
# Usage:
#   scripts/record-snapshots.sh
#   scripts/record-snapshots.sh --tier screens
#   scripts/record-snapshots.sh --only PutioUITests/ScreenshotWalkUITests/testVideoPlayerScreenshotWalk
#
# --only takes xcodebuild's own -only-testing: syntax. The leading test target
# selects the tier, so scoping to one test skips the other scheme entirely —
# about one minute against five for the full set.
#
# One simulator serves the whole run, and each tier builds once: the assert pass
# reuses the record pass's build products and the same booted device.

set -eu

# shellcheck disable=SC1007  # CDPATH= is a prefix assignment for cd, not an empty var
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORKSPACE=Putio.xcworkspace
XCCONFIG=Config/Verify.xcconfig

# Exact baseline counts a full tier run must produce, supplied by the Makefile
# so the tripwire numbers stay next to the rest of the build config. An
# unexpected count means a walk was skipped, crashed, or silently dropped
# baselines. Not checked for a scoped run, which writes a subset by definition.
expected_components=""
expected_screens=""

fatal() {
    echo "record-snapshots: $*" >&2
    exit 1
}

tiers="components screens"
# Read from the environment rather than interpolated into a shell command by the
# Makefile: a filter containing a space, a glob, or a quote would otherwise be
# word-split or executed.
only="${ONLY:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --tier)
            [ $# -ge 2 ] || fatal "--tier needs a value (components or screens)"
            tiers="$2"
            shift 2
            ;;
        --only)
            [ $# -ge 2 ] || fatal "--only needs a value"
            only="$2"
            shift 2
            ;;
        --expect-components)
            [ $# -ge 2 ] || fatal "--expect-components needs a value"
            expected_components="$2"
            shift 2
            ;;
        --expect-screens)
            [ $# -ge 2 ] || fatal "--expect-screens needs a value"
            expected_screens="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "record-snapshots: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
done

[ -n "$tiers" ] || fatal "--tier needs a value (components or screens)"

for tier in $tiers; do
    case "$tier" in
        components|screens) ;;
        *) fatal "unknown tier '$tier' (expected components or screens)" ;;
    esac
done

# --only names a test target, and that target decides which tier can run it.
# Deriving the tier rather than asking for it keeps the two from disagreeing.
if [ -n "$only" ]; then
    case "$only" in
        PutioTests/*|PutioTests) tiers=components ;;
        PutioUITests/*|PutioUITests) tiers=screens ;;
        *) fatal "--only must start with PutioTests or PutioUITests; got '$only'" ;;
    esac
fi

# Baselines are recorded with the licensed faces bundled, and a scoped screens
# run never reaches BrandFontTests — so nothing else would stop it writing a set
# of system-font captures that then become the committed reference.
ruby scripts/sync-brand-fonts.rb --check >/dev/null 2>&1 \
    || fatal "brand fonts are missing or do not match Config/BrandFonts.json. Run make fonts-setup before recording."

# One simulator for every tier in this run. The ephemeral script pins the status
# bar and locale so captures match between a maintainer's Mac and CI; an
# explicit PUTIO_SIMULATOR_ID skips creation and is never deleted.
ephemeral_id=""
if [ -n "${PUTIO_SIMULATOR_ID:-}" ]; then
    device_id="$PUTIO_SIMULATOR_ID"
    echo "Using simulator from PUTIO_SIMULATOR_ID: $device_id"
else
    device_id="$(./scripts/simctl-ephemeral-iphone.sh --label record)" || exit 1
    ephemeral_id="$device_id"
    echo "Using ephemeral simulator: $device_id"
fi

run_marker=""

cleanup() {
    [ -z "$run_marker" ] || rm -f "$run_marker"

    if [ -n "$ephemeral_id" ]; then
        xcrun simctl shutdown "$ephemeral_id" >/dev/null 2>&1 || true
        xcrun simctl delete "$ephemeral_id" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

destination="platform=iOS Simulator,id=$device_id"

run_tier() {
    tier="$1"

    case "$tier" in
        components)
            scheme=Putio
            bundle=build/verify.xcresult
            snapshots=PutioTests/__Snapshots__
            expected=$expected_components
            ;;
        screens)
            scheme=PutioE2E
            bundle=build/e2e-simulator.xcresult
            snapshots=PutioUITests/__Snapshots__
            expected=$expected_screens
            ;;
    esac

    # Positional params rather than a string: an unset filter has to expand to
    # no argument at all, and a quoted empty variable expands to an empty one
    # that xcodebuild rejects.
    set --
    if [ -n "$only" ]; then
        set -- "-only-testing:$only"
    fi

    echo
    echo "== $tier: building $scheme"
    xcodebuild -workspace "$WORKSPACE" -scheme "$scheme" -configuration Debug \
        -xcconfig "$XCCONFIG" -destination "$destination" build-for-testing -quiet

    # Recording is expected to fail: SnapshotTesting reports every rewritten
    # baseline as a failure so a record run can never be mistaken for a passing
    # one. verify-snapshot-recording.rb is what distinguishes that from a real
    # failure, so the exit status here is deliberately not checked.
    echo "== $tier: recording${only:+ ($only)}"
    # Written before the pass so `find ! -newer` can separate the baselines this
    # run produced from ones left behind by a test that no longer exists.
    run_marker="$(mktemp)"
    rm -rf "$bundle"
    TEST_RUNNER_PUTIO_RECORD_SNAPSHOTS=1 xcodebuild -workspace "$WORKSPACE" -scheme "$scheme" \
        -configuration Debug -xcconfig "$XCCONFIG" -destination "$destination" \
        test-without-building -resultBundlePath "$bundle" "$@" -quiet || true

    [ -d "$bundle" ] || fatal "$tier produced no result bundle; the run failed before testing."

    xcrun xcresulttool get test-results tests --path "$bundle" | ruby scripts/verify-snapshot-recording.rb \
        || fatal "$tier had failures beyond record-mode snapshot assertions; baselines may be incomplete."

    if [ -z "$only" ]; then
        [ -n "$expected" ] || fatal "$tier has no expected baseline count; pass --expect-$tier (the Makefile does)."

        # Counting alone cannot see a deleted test: its orphaned PNG stays on
        # disk and fills the slot the missing one left, so the total still
        # matches. Anything not written by this run is an orphan by definition.
        stale="$(find "$snapshots" -name '*.png' ! -newer "$run_marker" 2>/dev/null)"
        if [ -n "$stale" ]; then
            echo "record-snapshots: $tier left baselines this run did not write:" >&2
            echo "$stale" >&2
            fatal "A snapshot test was renamed or deleted. Remove the orphans and update the EXPECTED_*_BASELINES constants in the Makefile."
        fi

        count="$(find "$snapshots" -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
        if [ "$count" -ne "$expected" ]; then
            echo "record-snapshots: $tier wrote $count baselines, expected $expected." >&2
            fatal "If you intentionally added or removed snapshot tests, update the EXPECTED_*_BASELINES constants in the Makefile."
        fi
        echo "== $tier: recorded $count baselines under $snapshots/"
    else
        echo "== $tier: recorded a scoped subset under $snapshots/ (count not checked)"
    fi

    # Assert against what was just written, reusing the build products and the
    # booted device. Without this the maintainer pays a second full run to learn
    # whether the recording is self-consistent.
    echo "== $tier: asserting"
    rm -rf "$bundle"
    TEST_RUNNER_PUTIO_RECORD_SNAPSHOTS=0 xcodebuild -workspace "$WORKSPACE" -scheme "$scheme" \
        -configuration Debug -xcconfig "$XCCONFIG" -destination "$destination" \
        test-without-building -resultBundlePath "$bundle" "$@" -quiet \
        || fatal "$tier failed to assert against the baselines it just recorded. See $bundle."
}

for tier in $tiers; do
    run_tier "$tier"
done

echo
echo "Recorded and asserted: $tiers${only:+ ($only)}"
echo "Review the image diff and commit deliberately."
