// swift-tools-version: 6.2

import PackageDescription

// Google ships the Cast sender SDK only as a CocoaPods pod or a downloadable
// xcframework. This package wraps Google's own release archive so the iOS shell
// links it through Swift Package Manager without vendoring the binary.
let package = Package(
  name: "GoogleCastSDK",
  platforms: [.iOS(.v15)],
  products: [
    .library(name: "GoogleCast", targets: ["GoogleCast"])
  ],
  targets: [
    .binaryTarget(
      name: "GoogleCast",
      url: "https://dl.google.com/dl/chromecast/sdk/ios/GoogleCastSDK-ios-4.8.4_dynamic.zip",
      checksum: "c9c3a794e8585198b59c6bb7da5418a3194ffa1ffa6f9a1cbdf4dc0ea26dc6cf"
    )
  ]
)
