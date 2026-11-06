// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "StatefulViewController",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "StatefulViewController", targets: ["StatefulViewController"])
    ],
    targets: [
        .target(name: "StatefulViewController")
    ],
    swiftLanguageModes: [.v5]
)
