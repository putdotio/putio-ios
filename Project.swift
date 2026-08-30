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

private func brandFontResourceElements(for platform: String) -> [ResourceFileElement] {
  brandFontNames(for: platform).map { name in
    .glob(pattern: .relativeToManifest("\(brandFontManifest.directory)/\(name)"))
  }
}

private func brandFontResources(for platform: String) -> ResourceFileElements {
  .resources(brandFontResourceElements(for: platform))
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
        "UIBackgroundModes": ["audio"],
        "UILaunchScreen": [:],
        "UIUserInterfaceStyle": "Dark",
      ]),
      resources: brandFontResources(for: "ios"),
      buildableFolders: ["Apps/iOS/Sources", "Apps/Shared/Sources"],
      scripts: [
        .post(
          script: """
            set -euo pipefail
            destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/HarnessMedia"
            rm -rf "$destination"
            if [[ "$CONFIGURATION" != "Debug" ]]; then
              exit 0
            fi
            mkdir -p "$destination"
            cp "${SRCROOT}/Tests/HarnessMedia/direct-hls/runtime-proof.m3u8" "$destination/"
            cp "${SRCROOT}/Tests/HarnessMedia/direct-hls/runtime-proof-000.ts" "$destination/"
            """,
          name: "Bundle runtime-proof HLS fixture",
          basedOnDependencyAnalysis: false
        )
      ],
      dependencies: [
        .package(product: "PutioCore"),
        .target(name: "PutioWatch"),
      ]
    ),
    // The nightly flavor: same iOS sources, its own bundle ID so it installs
    // beside the dev and production apps, and the starfield icon that only
    // TestFlight ships. No watch companion; nightly is the phone app alone.
    .target(
      name: "PutioNightly",
      destinations: .iOS,
      product: .app,
      bundleId: "io.put.nightly.ios",
      deploymentTargets: .iOS("26.0"),
      infoPlist: .extendingDefault(with: [
        "CFBundleDisplayName": "put.io Nightly",
        "UIAppFonts": brandFontInfoPlist(for: "ios"),
        "UILaunchScreen": [:],
        "UIUserInterfaceStyle": "Dark",
      ]),
      resources: .resources(
        brandFontResourceElements(for: "ios") + [
          .glob(pattern: .relativeToManifest("Apps/iOS/Resources/Nightly.xcassets"))
        ]
      ),
      buildableFolders: ["Apps/iOS/Sources", "Apps/Shared/Sources"],
      dependencies: [
        .package(product: "PutioCore")
      ],
      settings: .settings(base: [
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"
      ])
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
      buildableFolders: [
        "Tests/ComponentSnapshots/Sources",
        "Tests/Shared/SnapshotSupport",
      ],
      dependencies: [
        .package(product: "PutioCore")
      ]
    ),
    .target(
      name: "PutioFeatureTests",
      destinations: .iOS,
      product: .unitTests,
      bundleId: "io.put.dev.ios.featuretests",
      deploymentTargets: .iOS("26.0"),
      infoPlist: .default,
      buildableFolders: [
        "Tests/iOS/Sources",
        "Tests/Shared/SnapshotSupport",
      ],
      dependencies: [
        .target(name: "Putio"),
        .package(product: "PutioCore"),
      ]
    ),
    .target(
      name: "PutioUITests",
      destinations: .iOS,
      product: .uiTests,
      bundleId: "io.put.dev.ios.uitests",
      deploymentTargets: .iOS("26.0"),
      infoPlist: .default,
      buildableFolders: ["Tests/iOSUITests/Sources"],
      dependencies: [
        .target(name: "Putio")
      ]
    ),
    .target(
      name: "PutioTVSnapshotTests",
      destinations: .tvOS,
      product: .unitTests,
      bundleId: "io.put.dev.tvos.snapshottests",
      deploymentTargets: .tvOS("26.0"),
      infoPlist: .default,
      buildableFolders: [
        "Tests/ComponentSnapshots/Sources",
        "Tests/Shared/SnapshotSupport",
      ],
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
