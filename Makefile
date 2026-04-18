.PHONY: bootstrap verify print-simulator-destination print-simulator-device run-simulator download-ios-platform op-local-config beta release

bootstrap:
	bundle config set --local path vendor/bundle
	bundle install
	bundle exec pod install

verify:
	xcodebuild -list -workspace Putio.xcworkspace
	@destination="$$(./scripts/xcode-iphone-simulator-destination.sh --workspace Putio.xcworkspace --scheme Putio 2>/dev/null || true)"; \
	if [ -n "$$destination" ]; then \
		echo "Using Xcode iPhone simulator destination: $$destination"; \
		xcodebuild -workspace Putio.xcworkspace -scheme Putio -configuration Debug -destination "$$destination" build CODE_SIGNING_ALLOWED=NO; \
	else \
		echo "No Xcode-advertised iPhone simulator destination on iOS 26.0 or newer. Falling back to the installed iphonesimulator SDK."; \
		xcodebuild -workspace Putio.xcworkspace -scheme Putio -configuration Debug -sdk iphonesimulator build CODE_SIGNING_ALLOWED=NO; \
	fi

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
	@./scripts/op-fastlane.sh $(if $(VAULT),--vault "$(VAULT)") $(if $(ITEM),--item "$(ITEM)") beta

release:
	@./scripts/op-fastlane.sh $(if $(VAULT),--vault "$(VAULT)") $(if $(ITEM),--item "$(ITEM)") release
