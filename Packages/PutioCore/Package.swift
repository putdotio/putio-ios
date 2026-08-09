// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "PutioCore",
  platforms: [
    .iOS(.v26),
    .watchOS(.v26),
    .tvOS(.v26),
    .macOS(.v15),
  ],
  products: [
    .library(name: "PutioCore", targets: ["PutioCore"])
  ],
  targets: [
    .target(name: "PutioCore"),
    .testTarget(name: "PutioCoreTests", dependencies: ["PutioCore"]),
  ]
)
