.PHONY: bootstrap bootstrap-ci doctor icons-sync icons-verify tokens-sync tokens-verify type-scale-sync type-scale-verify fonts-setup fonts-check verify verify-fast e2e-simulator screenshots-record screenshots-record-components screenshots-record-screens print-simulator-destination print-simulator-device run-simulator download-ios-platform secrets-setup secrets-clean vref vref-validate vref-serve beta release store-screenshots store-screenshots-check playwright-chromium store-images store-images-check

# Result bundle paths shared by verify / e2e-simulator / screenshots-record.
VERIFY_RESULT_BUNDLE := build/verify.xcresult
E2E_RESULT_BUNDLE := build/e2e-simulator.xcresult

# Exact baseline counts screenshots-record must produce. Update these when
# adding or removing snapshot tests — an unexpected count means a walk was
# skipped, crashed, or silently dropped baselines.
EXPECTED_COMPONENT_BASELINES := 11
EXPECTED_WALK_BASELINES := 13

bootstrap: doctor
	bundle config set --local path vendor/bundle
	bundle install
	bundle exec pod install
	pnpm install --frozen-lockfile
	git config core.hooksPath .githooks

doctor:
	@./scripts/doctor.sh

bootstrap-ci:
	@./scripts/bootstrap-ci.sh

icons-sync:
	@ruby scripts/sync-phosphor-icons.rb

icons-verify:
	@ruby scripts/sync-phosphor-icons.rb --check

tokens-sync:
	@ruby scripts/sync-design-tokens.rb

tokens-verify:
	@ruby scripts/sync-design-tokens.rb --check

type-scale-sync:
	@ruby scripts/sync-type-scale.rb

type-scale-verify:
	@ruby scripts/sync-type-scale.rb --check

fonts-setup:
	@ruby scripts/sync-brand-fonts.rb

fonts-check:
	@ruby scripts/sync-brand-fonts.rb --check

verify-fast: icons-verify tokens-verify type-scale-verify
	@if git ls-files | grep -iE '\.(otf|ttf|ttc)$$'; then \
		echo "verify-fast: licensed font binaries must never be committed (see CONTRIBUTING.md)." >&2; \
		exit 1; \
	fi
	plutil -lint Putio/en.lproj/*.strings
	xcodebuild -list -workspace Putio.xcworkspace

verify: verify-fast
	@set -e; ephemeral_id=""; \
	if [ -n "$${PUTIO_SIMULATOR_ID:-}" ]; then \
		device_id="$$PUTIO_SIMULATOR_ID"; \
		echo "Using simulator from PUTIO_SIMULATOR_ID: $$device_id"; \
	else \
		device_id="$$(./scripts/simctl-ephemeral-iphone.sh --label verify)" || exit 1; \
		ephemeral_id="$$device_id"; \
		echo "Using ephemeral simulator: $$device_id"; \
	fi; \
	trap 'if [ -n "$$ephemeral_id" ]; then xcrun simctl shutdown "$$ephemeral_id" >/dev/null 2>&1 || true; xcrun simctl delete "$$ephemeral_id" >/dev/null 2>&1 || true; fi' EXIT; \
	destination="platform=iOS Simulator,id=$$device_id"; \
	echo "Using iPhone simulator destination: $$destination"; \
	rm -rf $(VERIFY_RESULT_BUNDLE); \
	xcodebuild -workspace Putio.xcworkspace -scheme Putio -configuration Debug -xcconfig Config/Verify.xcconfig -destination "$$destination" build-for-testing -quiet; \
	echo "Test results will be written to $(VERIFY_RESULT_BUNDLE)"; \
	TEST_RUNNER_PUTIO_RECORD_SNAPSHOTS="$${PUTIO_RECORD_SNAPSHOTS:-0}" xcodebuild -workspace Putio.xcworkspace -scheme Putio -configuration Debug -xcconfig Config/Verify.xcconfig -destination "$$destination" test-without-building -resultBundlePath $(VERIFY_RESULT_BUNDLE) -quiet

e2e-simulator:
	@set -e; ephemeral_id=""; \
	if [ -n "$${PUTIO_SIMULATOR_ID:-}" ]; then \
		device_id="$$PUTIO_SIMULATOR_ID"; \
		echo "Using simulator from PUTIO_SIMULATOR_ID: $$device_id"; \
	else \
		device_id="$$(./scripts/simctl-ephemeral-iphone.sh --label e2e)" || exit 1; \
		ephemeral_id="$$device_id"; \
		echo "Using ephemeral simulator: $$device_id"; \
	fi; \
	trap 'if [ -n "$$ephemeral_id" ]; then xcrun simctl shutdown "$$ephemeral_id" >/dev/null 2>&1 || true; xcrun simctl delete "$$ephemeral_id" >/dev/null 2>&1 || true; fi' EXIT; \
	destination="platform=iOS Simulator,id=$$device_id"; \
	echo "Using iPhone simulator destination: $$destination"; \
	rm -rf $(E2E_RESULT_BUNDLE); \
	xcodebuild -workspace Putio.xcworkspace -scheme PutioE2E -configuration Debug -xcconfig Config/Verify.xcconfig -destination "$$destination" build-for-testing -quiet; \
	echo "Test results will be written to $(E2E_RESULT_BUNDLE)"; \
	TEST_RUNNER_PUTIO_RECORD_SNAPSHOTS="$${PUTIO_RECORD_SNAPSHOTS:-0}" xcodebuild -workspace Putio.xcworkspace -scheme PutioE2E -configuration Debug -xcconfig Config/Verify.xcconfig -destination "$$destination" test-without-building -resultBundlePath $(E2E_RESULT_BUNDLE) -quiet

# Records baselines and asserts against them in the same run, so a green exit
# means the recording is self-consistent. Scope with ONLY= to skip the tier you
# did not touch:
#
#   make screenshots-record
#   make screenshots-record ONLY=PutioUITests/ScreenshotWalkUITests/testVideoPlayerScreenshotWalk
#
# ONLY takes xcodebuild's -only-testing: syntax; the leading test target picks
# the tier. screenshots-record-components and -screens cover the common case of
# wanting one whole tier.
#
# It reaches the script through the environment rather than the command line, so
# a filter containing a space or a shell metacharacter is passed through intact
# instead of being word-split or executed.
export ONLY
RECORD_ARGS := --expect-components $(EXPECTED_COMPONENT_BASELINES) --expect-screens $(EXPECTED_WALK_BASELINES)

screenshots-record:
	@./scripts/record-snapshots.sh $(RECORD_ARGS)

screenshots-record-components:
	@./scripts/record-snapshots.sh --tier components $(RECORD_ARGS)

screenshots-record-screens:
	@./scripts/record-snapshots.sh --tier screens $(RECORD_ARGS)

print-simulator-destination:
	@./scripts/xcode-iphone-simulator-destination.sh --workspace Putio.xcworkspace --scheme Putio

print-simulator-device:
	@./scripts/simctl-iphone-device-id.sh

run-simulator:
	@./scripts/run-simulator-app.sh --workspace Putio.xcworkspace --scheme Putio

download-ios-platform:
	xcodebuild -downloadPlatform iOS

secrets-setup:
	@./scripts/secrets-setup.sh

secrets-clean:
	rm -f Config/Local.xcconfig

beta:
	@echo "make beta is CI-only. Use .github/workflows/beta.yml via GitHub Actions." >&2
	@exit 1

release:
	@echo "make release is CI-only. Use .github/workflows/release.yml via GitHub Actions." >&2
	@exit 1

vref:
	node scripts/vref.mjs build

vref-validate:
	node scripts/vref.mjs validate

vref-serve:
	node scripts/vref.mjs serve

store-screenshots:
	node scripts/store-screenshots.mjs

store-screenshots-check:
	node scripts/store-screenshots.mjs --check

# pnpm 10+ blocks postinstall scripts unless a package is allowlisted, so
# `pnpm install` gives us the playwright package without a browser to drive.
# Installing here rather than allowlisting the postinstall keeps `make bootstrap`
# from pulling ~150MB of Chromium for everyone who never renders store images.
# Idempotent, and a no-op once the browser is present.
playwright-chromium:
	@pnpm exec playwright install chromium

store-images: store-screenshots playwright-chromium
	node scripts/store-images.mjs

store-images-check: store-screenshots playwright-chromium
	node scripts/store-images.mjs --check
