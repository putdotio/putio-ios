.PHONY: bootstrap bootstrap-ci verify e2e-simulator print-simulator-destination print-simulator-device run-simulator download-ios-platform op-local-config beta release

bootstrap:
	bundle config set --local path vendor/bundle
	bundle install
	bundle exec pod install

bootstrap-ci:
	@./scripts/bootstrap-ci.sh

verify:
	xcodebuild -list -workspace Putio.xcworkspace
	@destination="$$(./scripts/xcode-iphone-simulator-destination.sh --workspace Putio.xcworkspace --scheme Putio 2>/dev/null || true)"; \
	if [ -z "$$destination" ]; then \
		device_id="$$(./scripts/simctl-iphone-device-id.sh 2>/dev/null || true)"; \
		if [ -n "$$device_id" ]; then \
			destination="platform=iOS Simulator,id=$$device_id"; \
		fi; \
	fi; \
	if [ -z "$$destination" ]; then \
		echo "No iPhone simulator destination available. Install the iOS simulator runtime or run make download-ios-platform." >&2; \
		exit 1; \
	fi; \
	echo "Using iPhone simulator destination: $$destination"; \
	xcodebuild -workspace Putio.xcworkspace -scheme Putio -configuration Debug -xcconfig Config/Verify.xcconfig -destination "$$destination" build-for-testing -quiet; \
	xcodebuild -workspace Putio.xcworkspace -scheme Putio -configuration Debug -xcconfig Config/Verify.xcconfig -destination "$$destination" test-without-building -quiet

e2e-simulator:
	@destination="$$(./scripts/xcode-iphone-simulator-destination.sh --workspace Putio.xcworkspace --scheme PutioE2E 2>/dev/null || true)"; \
	if [ -z "$$destination" ]; then \
		device_id="$$(./scripts/simctl-iphone-device-id.sh 2>/dev/null || true)"; \
		if [ -n "$$device_id" ]; then \
			destination="platform=iOS Simulator,id=$$device_id"; \
		fi; \
	fi; \
	if [ -z "$$destination" ]; then \
		echo "No iPhone simulator destination available. Install the iOS simulator runtime or run make download-ios-platform." >&2; \
		exit 1; \
	fi; \
	echo "Using iPhone simulator destination: $$destination"; \
	xcodebuild -workspace Putio.xcworkspace -scheme PutioE2E -configuration Debug -xcconfig Config/Verify.xcconfig -destination "$$destination" build-for-testing -quiet; \
	xcodebuild -workspace Putio.xcworkspace -scheme PutioE2E -configuration Debug -xcconfig Config/Verify.xcconfig -destination "$$destination" test-without-building -quiet

print-simulator-destination:
	@./scripts/xcode-iphone-simulator-destination.sh --workspace Putio.xcworkspace --scheme Putio

print-simulator-device:
	@./scripts/simctl-iphone-device-id.sh

run-simulator:
	@./scripts/run-simulator-app.sh --workspace Putio.xcworkspace --scheme Putio

download-ios-platform:
	xcodebuild -downloadPlatform iOS

op-local-config:
	@./scripts/op-local-config.sh $(if $(VAULT),--vault "$(VAULT)") $(if $(ITEM),--item "$(ITEM)")

beta:
	@echo "make beta is CI-only. Use .github/workflows/beta.yml via GitHub Actions." >&2
	@exit 1

release:
	@echo "make release is CI-only. Use .github/workflows/release.yml via GitHub Actions." >&2
	@exit 1
