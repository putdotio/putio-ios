// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "PutioHarness",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(name: "putio-harness", targets: ["PutioHarness"])
  ],
  targets: [
    .target(name: "PutioHarnessKit"),
    .executableTarget(name: "PutioHarness", dependencies: ["PutioHarnessKit"]),
    .testTarget(name: "PutioHarnessKitTests", dependencies: ["PutioHarnessKit"]),
  ]
)
