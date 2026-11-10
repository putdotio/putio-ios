#!/bin/sh
# Builds one test scheme and runs it against an iPhone simulator.
#
# Usage:
#   scripts/xcodebuild-test.sh --scheme Putio --result-bundle build/verify.xcresult --label verify
#
# --parallel-workers N runs test classes on N clones of the simulator.
# --only-testing and --skip-testing take one xcodebuild test identifier each
# and repeat.
#
# A test that runs past its allowance fails instead of hanging the run.
#
# The simulator is ephemeral and deleted on exit, so parallel worktrees never
# collide. PUTIO_SIMULATOR_ID targets a specific device instead, and that one is
# never deleted.

set -eu

# shellcheck disable=SC1007  # CDPATH= is a prefix assignment for cd, not an empty var
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORKSPACE=Putio.xcworkspace
XCCONFIG=Config/Verify.xcconfig

scheme=""
bundle=""
label=""
workers=""
filters=""

fatal() {
    echo "xcodebuild-test: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --scheme)
            [ $# -ge 2 ] || fatal "--scheme needs a value"
            scheme="$2"
            shift 2
            ;;
        --result-bundle)
            [ $# -ge 2 ] || fatal "--result-bundle needs a value"
            bundle="$2"
            shift 2
            ;;
        --label)
            [ $# -ge 2 ] || fatal "--label needs a value"
            label="$2"
            shift 2
            ;;
        --parallel-workers)
            [ $# -ge 2 ] || fatal "--parallel-workers needs a value"
            workers="$2"
            shift 2
            ;;
        --only-testing)
            [ $# -ge 2 ] || fatal "--only-testing needs a value"
            filters="$filters
-only-testing:$2"
            shift 2
            ;;
        --skip-testing)
            [ $# -ge 2 ] || fatal "--skip-testing needs a value"
            filters="$filters
-skip-testing:$2"
            shift 2
            ;;
        -h|--help)
            # Print the comment header and stop at the first line that is not
            # one, rather than a fixed range that trimming the header turns into
            # a dump of the script's shell setup.
            awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
            exit 0
            ;;
        *)
            echo "xcodebuild-test: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
done

[ -n "$scheme" ] || fatal "--scheme is required"
[ -n "$bundle" ] || fatal "--result-bundle is required"
[ -n "$label" ] || fatal "--label is required"
case "$workers" in
    "") ;;
    *[!0-9]*|0) fatal "--parallel-workers must be a positive integer; got '$workers'" ;;
esac

# The Makefile hardcoded this path; a flag can be mistyped, and the run starts by
# rm -rf'ing whatever it names. Only accept a relative .xcresult path.
case "$bundle" in
    *.xcresult) ;;
    *) fatal "--result-bundle must name a .xcresult path; got '$bundle'" ;;
esac
case "$bundle" in
    /*|~*) fatal "--result-bundle must be relative to the repo; got '$bundle'" ;;
    *..*) fatal "--result-bundle must not traverse upward; got '$bundle'" ;;
esac

ephemeral_id=""
boot_pid=""
if [ -n "${PUTIO_SIMULATOR_ID:-}" ]; then
    device_id="$PUTIO_SIMULATOR_ID"
    echo "Using simulator from PUTIO_SIMULATOR_ID: $device_id"
else
    device_id="$(./scripts/simctl-ephemeral-device.sh --label "$label" --no-boot)" || exit 1
    ephemeral_id="$device_id"
    echo "Using ephemeral simulator: $device_id"
    ./scripts/simctl-ephemeral-device.sh --boot "$device_id" &
    boot_pid=$!
fi

cleanup() {
    [ -z "$boot_pid" ] || wait "$boot_pid" 2>/dev/null || true
    if [ -n "$ephemeral_id" ]; then
        xcrun simctl shutdown "$ephemeral_id" >/dev/null 2>&1 || true
        xcrun simctl delete "$ephemeral_id" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

destination="platform=iOS Simulator,id=$device_id"
echo "Using iPhone simulator destination: $destination"

rm -rf "$bundle"
xcodebuild -workspace "$WORKSPACE" -scheme "$scheme" -configuration Debug \
    -xcconfig "$XCCONFIG" -destination "$destination" -onlyUsePackageVersionsFromResolvedFile \
    build-for-testing -quiet

if [ -n "$boot_pid" ]; then
    wait "$boot_pid" || fatal "booting $device_id failed"
    boot_pid=""
fi

set -- -collect-test-diagnostics never -enableCodeCoverage NO \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
    -maximum-test-execution-time-allowance 300
if [ -n "$workers" ]; then
    set -- "$@" -parallel-testing-enabled YES -parallel-testing-worker-count "$workers"
fi
set -f
old_ifs=$IFS
IFS='
'
for filter in $filters; do
    set -- "$@" "$filter"
done
IFS=$old_ifs
set +f

echo "Test results will be written to $bundle"
TEST_RUNNER_PUTIO_RECORD_SNAPSHOTS="${PUTIO_RECORD_SNAPSHOTS:-0}" \
    xcodebuild -workspace "$WORKSPACE" -scheme "$scheme" -configuration Debug \
    -xcconfig "$XCCONFIG" -destination "$destination" test-without-building \
    -resultBundlePath "$bundle" "$@" -quiet
