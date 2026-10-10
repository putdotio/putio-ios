// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "PutioDependencies",
  dependencies: [
    .package(path: "../Packages/GoogleCastSDK"),
    .package(path: "../Packages/SentrySDK"),
    .package(url: "https://github.com/intercom/intercom-ios-sp", exact: "19.9.0"),
  ]
)
