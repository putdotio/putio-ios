import Foundation
import ProjectDescription

private struct BrandFontManifest: Decodable {
  struct Font: Decodable {
    let platforms: [String]
  }

  let directory: String
  let files: [String: Font]
}

private func loadBrandFontManifest() -> BrandFontManifest {
  let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Config/BrandFonts.json")
  do {
    return try JSONDecoder().decode(BrandFontManifest.self, from: Data(contentsOf: url))
  } catch {
    fatalError("Config/BrandFonts.json is invalid: \(error)")
  }
}

private let brandFontManifest = loadBrandFontManifest()

private func brandFontNames(for platform: String) -> [String] {
  brandFontManifest.files
    .filter { $0.value.platforms.contains(platform) }
    .map(\.key)
    .sorted()
}

private func brandFontResources(for platform: String) -> ResourceFileElements {
  .resources(
    brandFontNames(for: platform).map { name in
      .glob(pattern: .relativeToManifest("\(brandFontManifest.directory)/\(name)"))
    }
  )
}

private func brandFontInfoPlist(for platform: String) -> Plist.Value {
  .array(brandFontNames(for: platform).map(Plist.Value.string))
}

let project = Project(
  name: "Putio",
  organizationName: "put.io",
  packages: [
    .local(path: "Packages/PutioCore")
  ],
  targets: [
    .target(
      name: "Putio",
      destinations: .iOS,
      product: .app,
      bundleId: "io.put.dev.ios",
      deploymentTargets: .iOS("26.0"),
      infoPlist: .extendingDefault(with: [
        "CFBundleDisplayName": "put.io",
        "UIAppFonts": brandFontInfoPlist(for: "ios"),
        "UILaunchScreen": [:],
        "UIUserInterfaceStyle": "Dark",
      ]),
      resources: brandFontResources(for: "ios"),
      buildableFolders: ["Apps/iOS/Sources", "Apps/Shared/Sources"],
      dependencies: [
        .package(product: "PutioCore"),
        .target(name: "PutioWatch"),
      ]
    ),
    .target(
      name: "PutioWatch",
      destinations: .watchOS,
      product: .app,
      bundleId: "io.put.dev.ios.watchkitapp",
      deploymentTargets: .watchOS("26.0"),
      infoPlist: .extendingDefault(with: [
        "CFBundleDisplayName": "put.io",
        "UIAppFonts": brandFontInfoPlist(for: "watchos"),
        "WKApplication": true,
        "WKCompanionAppBundleIdentifier": "io.put.dev.ios",
        "WKRunsIndependentlyOfCompanionApp": false,
        "WKWatchOnly": false,
      ]),
      resources: brandFontResources(for: "watchos"),
      buildableFolders: ["Apps/watchOS/Sources", "Apps/Shared/Sources"],
      dependencies: [
        .package(product: "PutioCore")
      ]
    ),
    .target(
      name: "PutioSnapshotTests",
      destinations: .iOS,
      product: .unitTests,
      bundleId: "io.put.dev.ios.snapshottests",
      deploymentTargets: .iOS("26.0"),
      infoPlist: .default,
      buildableFolders: ["Tests/ComponentSnapshots/Sources"],
      dependencies: [
        .package(product: "PutioCore")
      ]
    ),
    .target(
      name: "PutioTVSnapshotTests",
      destinations: .tvOS,
      product: .unitTests,
      bundleId: "io.put.dev.tvos.snapshottests",
      deploymentTargets: .tvOS("26.0"),
      infoPlist: .default,
      buildableFolders: ["Tests/ComponentSnapshots/Sources"],
      dependencies: [
        .package(product: "PutioCore")
      ]
    ),
    .target(
      name: "PutioTV",
      destinations: .tvOS,
      product: .app,
      bundleId: "io.put.dev.tvos",
      deploymentTargets: .tvOS("26.0"),
      infoPlist: .extendingDefault(with: [
        "CFBundleDisplayName": "put.io",
        "UIAppFonts": brandFontInfoPlist(for: "tvos"),
        "UILaunchScreen": [:],
        "UIUserInterfaceStyle": "Dark",
      ]),
      resources: brandFontResources(for: "tvos"),
      buildableFolders: ["Apps/tvOS/Sources", "Apps/Shared/Sources"],
      dependencies: [
        .package(product: "PutioCore")
      ]
    ),
  ]
)
