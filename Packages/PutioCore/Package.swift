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
    // Temporary cross-repository stack pin. Return to a released version when
    // putdotio/putio-sdk-swift#51 lands and is published.
    .package(
      url: "https://github.com/putdotio/putio-sdk-swift",
      revision: "f30692806fcb19eaf4e5ce89028a758c36dcd1ec"
    )
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
