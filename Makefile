.PHONY: bootstrap verify download-ios-platform

bootstrap:
	bundle install
	bundle exec pod install

verify:
	xcodebuild -list -workspace Putio.xcworkspace
	xcodebuild -workspace Putio.xcworkspace -scheme Putio -configuration Debug -sdk iphonesimulator build CODE_SIGNING_ALLOWED=NO

download-ios-platform:
	xcodebuild -downloadPlatform iOS
