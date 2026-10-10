// swift-tools-version: 6.2

import PackageDescription

// sentry-cocoa's own package declares seven binary targets, and SwiftPM
// downloads every one (about 800 MB) whichever product the app links. This
// wraps the single dynamic xcframework the iOS shell uses, as GoogleCastSDK does.
let package = Package(
  name: "SentrySDK",
  platforms: [.iOS(.v15)],
  products: [
    .library(name: "Sentry", targets: ["Sentry-Dynamic"])
  ],
  targets: [
    .binaryTarget(
      name: "Sentry-Dynamic",
      url:
        "https://github.com/getsentry/sentry-cocoa/releases/download/9.30.1/Sentry-Dynamic.xcframework.zip",
      checksum: "59d6ad91d58638686446344c4b8392731f113ea5b09d48034beb3c1728130fb4"
    )
  ]
)
