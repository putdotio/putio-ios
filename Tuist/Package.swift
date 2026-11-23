// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "PutioDependencies",
  dependencies: [
    .package(path: "../Packages/GoogleCastSDK"),
    .package(path: "../Packages/SentrySDK"),
    .package(url: "https://github.com/intercom/intercom-ios-sp", exact: "19.12.0"),
    .package(url: "https://github.com/superuser404notfound/AetherEngine", exact: "7.72.0"),
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.7"),
  ]
)
