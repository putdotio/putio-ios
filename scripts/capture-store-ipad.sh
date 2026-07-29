#!/bin/sh
# Captures the App Store screenshot set for iPad, which has no walk of its own.
#
# The iPhone set needs no capture: the regression walk is pinned to iPhone 17
# Pro Max, whose output is already Apple's 6.9" size, so those store images are
# a selection over baselines CI pixel-compares. iPad is not in that suite — a
# second device tests the same code paths and would roughly double a 15-minute
# job — so this lane records it on demand and commits the result.
#
# The captures land in PutioUITests/__Captures__/ipad-13/, deliberately not
# __Snapshots__/: nothing asserts them. Their review gate is the image diff on
# the marketing images `mise run store-images` renders from them.
#
#   mise run store-capture-ipad

set -eu

# shellcheck disable=SC1007  # CDPATH= is a prefix assignment for cd, not an empty var
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORKSPACE=Putio.xcworkspace
SCHEME=PutioE2E
XCCONFIG=Config/Verify.xcconfig
BUNDLE=build/store-capture-ipad.xcresult
DEVICE=ipad-13
CAPTURES="PutioUITests/__Captures__/$DEVICE"
DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB

# The two walks that between them reach every marketing screen. The first also
# captures trash, which is not in the store set, so the prune below drops it.
TESTS="PutioUITests/ScreenshotWalkUITests/testMainScreensScreenshotWalk
PutioUITests/ScreenshotWalkUITests/testVideoPlayerScreenshotWalk"

fatal() {
    echo "capture-store-ipad: $*" >&2
    exit 1
}

# These are marketing assets, and nothing asserts them — a system-font capture
# would reach the App Store rather than fail a test.
ruby scripts/sync-brand-fonts.rb --check >/dev/null 2>&1 \
    || fatal "brand fonts are missing or do not match Config/BrandFonts.json. Run mise run fonts-setup first."

device_id="$(./scripts/simctl-ephemeral-device.sh --label store-ipad --device-type "$DEVICE_TYPE")" || exit 1
echo "Using ephemeral iPad: $device_id"

cleanup() {
    xcrun simctl shutdown "$device_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$device_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT

destination="platform=iOS Simulator,id=$device_id"

set --
for test in $TESTS; do
    set -- "$@" "-only-testing:$test"
done

echo "== building $SCHEME for iPad"
xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Debug \
    -xcconfig "$XCCONFIG" -destination "$destination" build-for-testing -quiet

# Recording is expected to report failures: SnapshotTesting fails every image it
# rewrites so a record run can never be mistaken for a passing one.
# verify-snapshot-recording.rb is what separates that from a real failure, which
# is why this exit status is deliberately not checked.
echo "== capturing into $CAPTURES/"
rm -rf "$BUNDLE" "$CAPTURES"
mkdir -p "$CAPTURES"
TEST_RUNNER_PUTIO_RECORD_SNAPSHOTS=1 \
TEST_RUNNER_PUTIO_SNAPSHOT_DIR="$ROOT/$CAPTURES" \
    xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Debug \
    -xcconfig "$XCCONFIG" -destination "$destination" \
    test-without-building -resultBundlePath "$BUNDLE" "$@" -quiet || true

[ -d "$BUNDLE" ] || fatal "the run produced no result bundle; it failed before testing."

xcrun xcresulttool get test-results tests --path "$BUNDLE" | ruby scripts/verify-snapshot-recording.rb \
    || fatal "the walk had failures beyond record-mode snapshot assertions. See $BUNDLE."

# xcodebuild exits 0 for a -only-testing: identifier that matches nothing, so a
# renamed test would otherwise capture nothing and still report success.
[ -n "$(find "$CAPTURES" -name '*.png' 2>/dev/null | head -1)" ] \
    || fatal "no captures were written. Check the -only-testing: identifiers in this script."

# Keep only what the store set declares: an unused 2064x2752 capture is a
# megabyte of committed weight that no config references.
ruby -rjson -e '
  dir, device = ARGV
  wanted = JSON.parse(File.read("Config/StoreScreenshots.json"))
    .fetch("devices").fetch(device).fetch("screenshots").map { |slot| slot.fetch("baseline") }
  Dir.glob(File.join(dir, "*.png")).sort.each do |path|
    next if wanted.include?(File.basename(path))
    puts "  dropping #{File.basename(path)} (captured by the walk, not in the #{device} store set)"
    File.delete(path)
  end
' "$CAPTURES" "$DEVICE"

# Proves the size Apple will be sent, read from the images rather than from what
# this script believes the device to be.
node scripts/store-screenshots.ts --check

echo
echo "Captured $(find "$CAPTURES" -name '*.png' | wc -l | tr -d ' ') iPad screenshots under $CAPTURES/"
echo "Next: mise run store-images, then review the image diff and commit."
