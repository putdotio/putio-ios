.PHONY: bootstrap bootstrap-ci doctor icons-sync icons-verify tokens-sync tokens-verify verify verify-fast e2e-simulator screenshots-record print-simulator-destination print-simulator-device run-simulator download-ios-platform secrets-setup secrets-clean beta release

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

verify-fast: icons-verify tokens-verify
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
	rm -rf build/verify.xcresult; \
	xcodebuild -workspace Putio.xcworkspace -scheme Putio -configuration Debug -xcconfig Config/Verify.xcconfig -destination "$$destination" build-for-testing -quiet; \
	echo "Test results will be written to build/verify.xcresult"; \
	xcodebuild -workspace Putio.xcworkspace -scheme Putio -configuration Debug -xcconfig Config/Verify.xcconfig -destination "$$destination" test-without-building -resultBundlePath build/verify.xcresult -quiet

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
	rm -rf build/e2e-simulator.xcresult; \
	xcodebuild -workspace Putio.xcworkspace -scheme PutioE2E -configuration Debug -xcconfig Config/Verify.xcconfig -destination "$$destination" build-for-testing -quiet; \
	echo "Test results will be written to build/e2e-simulator.xcresult"; \
	TEST_RUNNER_PUTIO_RECORD_SNAPSHOTS="$${PUTIO_RECORD_SNAPSHOTS:-0}" xcodebuild -workspace Putio.xcworkspace -scheme PutioE2E -configuration Debug -xcconfig Config/Verify.xcconfig -destination "$$destination" test-without-building -resultBundlePath build/e2e-simulator.xcresult -quiet

screenshots-record:
	@rm -rf PutioUITests/__Snapshots__; \
	PUTIO_RECORD_SNAPSHOTS=1 $(MAKE) e2e-simulator; status=$$?; \
	if [ ! -d build/e2e-simulator.xcresult ]; then \
		echo "screenshots-record: no result bundle was produced; the run failed before testing (exit $$status)." >&2; \
		exit 1; \
	fi; \
	if ! xcrun xcresulttool get test-results tests --path build/e2e-simulator.xcresult | ruby scripts/verify-snapshot-recording.rb; then \
		echo "screenshots-record: the run had failures beyond record-mode snapshot assertions; baselines may be incomplete." >&2; \
		exit 1; \
	fi; \
	count="$$(find PutioUITests/__Snapshots__ -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"; \
	if [ "$$count" -eq 0 ]; then \
		echo "screenshots-record: no baselines were written; the run failed before recording (exit $$status)." >&2; \
		exit 1; \
	fi; \
	echo "Recorded $$count baselines under PutioUITests/__Snapshots__/. Review the image diff and commit deliberately."; \
	echo "(Recording runs report snapshot-test failures by design; rerun make e2e-simulator to verify against the new baselines.)"

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
