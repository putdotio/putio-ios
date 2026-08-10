import ProjectDescription

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
        "UILaunchScreen": [:],
        "UIUserInterfaceStyle": "Dark",
      ]),
      buildableFolders: ["Apps/iOS/Sources"],
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
        "WKApplication": true,
        "WKCompanionAppBundleIdentifier": "io.put.dev.ios",
        "WKRunsIndependentlyOfCompanionApp": false,
        "WKWatchOnly": false,
      ]),
      buildableFolders: ["Apps/watchOS/Sources"],
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
        "UILaunchScreen": [:],
        "UIUserInterfaceStyle": "Dark",
      ]),
      buildableFolders: ["Apps/tvOS/Sources"],
      dependencies: [
        .package(product: "PutioCore")
      ]
    ),
  ]
)
