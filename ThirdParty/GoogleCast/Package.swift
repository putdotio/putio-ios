// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "GoogleCast",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "GoogleCast", targets: ["GoogleCast"])
    ],
    targets: [
        .binaryTarget(
            name: "GoogleCast",
            url: "https://dl.google.com/dl/chromecast/sdk/ios/GoogleCastSDK-ios-4.8.6_dynamic.zip",
            checksum: "55f6c21291a1315c68063f07e7d76225564bff70f2fd38caad135c71d66eb310"
        )
    ]
)
