.PHONY: bootstrap bootstrap-ci doctor icons-sync icons-verify tokens-sync tokens-verify type-scale-sync type-scale-verify fonts-setup fonts-check verify verify-fast e2e-simulator screenshots-record print-simulator-destination print-simulator-device run-simulator download-ios-platform secrets-setup secrets-clean beta release

# Result bundle paths shared by verify / e2e-simulator / screenshots-record.
VERIFY_RESULT_BUNDLE := build/verify.xcresult
E2E_RESULT_BUNDLE := build/e2e-simulator.xcresult

# Exact baseline counts screenshots-record must produce. Update these when
# adding or removing snapshot tests — an unexpected count means a walk was
# skipped, crashed, or silently dropped baselines.
EXPECTED_COMPONENT_BASELINES := 11
EXPECTED_WALK_BASELINES := 12

bootstrap: doctor
	bundle config set --local path vendor/bundle
	bundle install
	bundle exec pod install
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

screenshots-record:
	@rm -rf PutioUITests/__Snapshots__ PutioTests/__Snapshots__; \
	overall=0; \
	for target in verify e2e-simulator; do \
		case "$$target" in \
			verify) bundle=$(VERIFY_RESULT_BUNDLE); snapshots=PutioTests/__Snapshots__; expected=$(EXPECTED_COMPONENT_BASELINES);; \
			*) bundle=$(E2E_RESULT_BUNDLE); snapshots=PutioUITests/__Snapshots__; expected=$(EXPECTED_WALK_BASELINES);; \
		esac; \
		PUTIO_RECORD_SNAPSHOTS=1 $(MAKE) $$target; status=$$?; \
		if [ ! -d "$$bundle" ]; then \
			echo "screenshots-record: $$target produced no result bundle; the run failed before testing (exit $$status)." >&2; \
			overall=1; continue; \
		fi; \
		if ! xcrun xcresulttool get test-results tests --path "$$bundle" | ruby scripts/verify-snapshot-recording.rb; then \
			echo "screenshots-record: $$target had failures beyond record-mode snapshot assertions; baselines may be incomplete." >&2; \
			overall=1; continue; \
		fi; \
		count="$$(find $$snapshots -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"; \
		if [ "$$count" -ne "$$expected" ]; then \
			echo "screenshots-record: $$target wrote $$count baselines, expected $$expected (exit $$status)." >&2; \
			echo "If you intentionally added or removed snapshot tests, update the EXPECTED_*_BASELINES constants in the Makefile." >&2; \
			overall=1; continue; \
		fi; \
		echo "Recorded $$count baselines under $$snapshots/."; \
	done; \
	[ "$$overall" -eq 0 ] || exit 1; \
	echo "Review the image diffs and commit deliberately."; \
	echo "(Recording runs report snapshot-test failures by design; rerun make verify and make e2e-simulator to verify.)"

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
