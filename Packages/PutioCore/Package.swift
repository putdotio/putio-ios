// swift-tools-version: 6.2

import PackageDescription

let domainTargets: [Target] = [
  .target(
    name: "PutioDomain",
    dependencies: [
      .product(name: "PutioSDK", package: "putio-sdk-swift")
    ],
    resources: [.process("Resources")]
  ),
  .testTarget(
    name: "PutioDomainTests",
    dependencies: [
      "PutioDomain",
      .product(name: "PutioSDK", package: "putio-sdk-swift"),
    ],
    swiftSettings: [.swiftLanguageMode(.v5, .when(platforms: [.linux]))]
  ),
]

#if canImport(Darwin)
  let appleTargets: [Target] = [
    .target(
      name: "PutioCore",
      dependencies: [
        "PutioDomain",
        .product(name: "PutioSDK", package: "putio-sdk-swift"),
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
  let appleProducts: [Product] = [.library(name: "PutioCore", targets: ["PutioCore"])]
#else
  let appleTargets: [Target] = []
  let appleProducts: [Product] = []
#endif

let package = Package(
  name: "PutioCore",
  defaultLocalization: "en",
  platforms: [
    .iOS(.v26),
    .watchOS(.v26),
    .tvOS(.v26),
    .macOS(.v26),
  ],
  products: appleProducts + [.library(name: "PutioDomain", targets: ["PutioDomain"])],
  dependencies: [
    .package(url: "https://github.com/putdotio/putio-sdk-swift", from: "4.12.0")
  ],
  targets: domainTargets + appleTargets
)
