// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "PutioCore",
  platforms: [
    .iOS(.v26),
    .watchOS(.v26),
    .tvOS(.v26),
    .macOS(.v26),
  ],
  products: [
    .library(name: "PutioCore", targets: ["PutioCore"])
  ],
  dependencies: [
    .package(url: "https://github.com/putdotio/putio-sdk-swift", from: "3.3.0")
  ],
  targets: [
    .target(
      name: "PutioCore",
      dependencies: [
        .product(name: "PutioSDK", package: "putio-sdk-swift")
      ],
      resources: [.process("Resources")]
    ),
    .testTarget(
      name: "PutioCoreTests",
      dependencies: [
        "PutioCore",
        .product(name: "PutioSDK", package: "putio-sdk-swift"),
      ]
    ),
  ]
)
