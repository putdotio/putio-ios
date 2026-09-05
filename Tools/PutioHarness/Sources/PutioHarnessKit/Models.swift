import Foundation

public enum HarnessPlatform: String, CaseIterable, Codable, Sendable {
  case ios
  case watchos
  case tvos

  public var configuration: PlatformConfiguration {
    switch self {
    case .ios:
      PlatformConfiguration(
        scheme: "Putio",
        bundleIdentifier: "io.put.dev.ios",
        sdk: "iphonesimulator",
        destination: "generic/platform=iOS Simulator",
        productDirectory: "Debug-iphonesimulator",
        appName: "Putio.app",
        runtimePlatform: "iOS",
        deviceFamily: "iPhone",
        snapshotSuites: [
          SnapshotSuite(scheme: "Putio", target: "PutioSnapshotTests"),
          SnapshotSuite(scheme: "PutioFeatureTests", target: "PutioFeatureTests"),
        ],
        extraBuildSchemes: ["PutioNightly"]
      )
    case .watchos:
      PlatformConfiguration(
        scheme: "PutioWatch",
        bundleIdentifier: "io.put.dev.ios.watchkitapp",
        sdk: "watchsimulator",
        destination: "generic/platform=watchOS Simulator",
        productDirectory: "Debug-watchsimulator",
        appName: "PutioWatch.app",
        runtimePlatform: "watchOS",
        deviceFamily: "Apple Watch"
      )
    case .tvos:
      PlatformConfiguration(
        scheme: "PutioTV",
        bundleIdentifier: "io.put.dev.tvos",
        sdk: "appletvsimulator",
        destination: "generic/platform=tvOS Simulator",
        productDirectory: "Debug-appletvsimulator",
        appName: "PutioTV.app",
        runtimePlatform: "tvOS",
        deviceFamily: "Apple TV",
        snapshotSuites: [
          SnapshotSuite(scheme: "PutioTV", target: "PutioTVSnapshotTests")
        ]
      )
    }
  }
}

public struct SnapshotSuite: Equatable, Sendable {
  public let scheme: String
  public let target: String

  public init(scheme: String, target: String) {
    self.scheme = scheme
    self.target = target
  }
}

public struct PlatformConfiguration: Equatable, Sendable {
  public let scheme: String
  public let bundleIdentifier: String
  public let sdk: String
  public let destination: String
  public let productDirectory: String
  public let appName: String
  public let runtimePlatform: String
  public let deviceFamily: String
  public let snapshotSuites: [SnapshotSuite]
  // Flavor schemes on the same platform (the nightly app) that the build
  // command must also compile; runtime commands keep driving the main scheme.
  public let extraBuildSchemes: [String]

  public init(
    scheme: String,
    bundleIdentifier: String,
    sdk: String,
    destination: String,
    productDirectory: String,
    appName: String,
    runtimePlatform: String,
    deviceFamily: String,
    snapshotSuites: [SnapshotSuite] = [],
    extraBuildSchemes: [String] = []
  ) {
    self.scheme = scheme
    self.bundleIdentifier = bundleIdentifier
    self.sdk = sdk
    self.destination = destination
    self.productDirectory = productDirectory
    self.appName = appName
    self.runtimePlatform = runtimePlatform
    self.deviceFamily = deviceFamily
    self.snapshotSuites = snapshotSuites
    self.extraBuildSchemes = extraBuildSchemes
  }
}

public enum PlatformSelection: Equatable, Sendable {
  case one(HarnessPlatform)
  case all

  public var platforms: [HarnessPlatform] {
    switch self {
    case .one(let platform): [platform]
    case .all: HarnessPlatform.allCases
    }
  }
}

public enum OutputFormat: String, Equatable, Sendable {
  case text
  case json
}

public enum CaptureScenario: String, CaseIterable, Equatable, Sendable {
  case signedOut = "signed-out"
  case gallery
  case signedIn = "signed-in"
}

public enum JourneyScenario: String, CaseIterable, Equatable, Sendable {
  case filesBrowser = "files-browser"

  var fixtureSet: String {
    switch self {
    case .filesBrowser: "seeded-runtime-loop-v3"
    }
  }
}

public enum SurfaceCommand: String, CaseIterable, Equatable, Sendable {
  case build
  case boot
  case launch
  case exercise
  case screenshot
  case record
  case proof
}

public enum HarnessInvocation: Equatable, Sendable {
  case help
  case doctor(output: OutputFormat)
  case surface(
    command: SurfaceCommand,
    platforms: PlatformSelection,
    runID: String?,
    recordSeconds: Int,
    scenario: CaptureScenario,
    output: OutputFormat
  )
  case test(
    platform: HarnessPlatform,
    recordSnapshots: Bool,
    output: OutputFormat
  )
  case journey(
    platform: HarnessPlatform,
    scenario: JourneyScenario,
    runID: String?,
    output: OutputFormat
  )
  case authStatus(output: OutputFormat)
  case liveFixture(output: OutputFormat)
  case publish(artifact: String, repository: String, pullRequest: Int, output: OutputFormat)
}

enum LiveFixtureContract {
  static let profile = "devs-auto"
  static let rootFolder = "putio-ios-harness"
}

public struct HarnessResult: Codable, Sendable {
  public let status: String
  public let command: String
  public let platforms: [String]
  public let artifacts: [String]
  public let message: String

  public init(
    status: String = "ok",
    command: String,
    platforms: [String] = [],
    artifacts: [String] = [],
    message: String
  ) {
    self.status = status
    self.command = command
    self.platforms = platforms
    self.artifacts = artifacts
    self.message = message
  }
}

public struct DoctorCheck: Codable, Sendable {
  public enum Status: String, Codable, Sendable {
    case ok
    case warning
    case failed
  }

  public let name: String
  public let status: Status
  public let required: Bool
  public let detail: String

  public init(name: String, status: Status, required: Bool, detail: String) {
    self.name = name
    self.status = status
    self.required = required
    self.detail = detail
  }
}

public struct DoctorReport: Codable, Sendable {
  public let status: String
  public let checks: [DoctorCheck]

  public init(checks: [DoctorCheck]) {
    self.checks = checks
    status = checks.contains { $0.required && $0.status == .failed } ? "failed" : "ok"
  }
}

public struct ProofArtifact: Codable, Equatable, Sendable {
  public let kind: String
  public let path: String
  public let bytes: Int
  public let sha256: String

  public init(kind: String, path: String, bytes: Int, sha256: String) {
    self.kind = kind
    self.path = path
    self.bytes = bytes
    self.sha256 = sha256
  }
}

public struct ProofManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let runID: String
  public let commit: String
  public let createdAt: String
  public let command: String
  public let platform: HarnessPlatform
  public let scheme: String
  public let bundleIdentifier: String
  public let runtime: String
  public let deviceType: String
  public let simulatorName: String
  public let fixtureSet: String
  public let artifacts: [ProofArtifact]

  public init(
    schemaVersion: Int = 1,
    runID: String,
    commit: String,
    createdAt: String,
    command: String,
    platform: HarnessPlatform,
    scheme: String,
    bundleIdentifier: String,
    runtime: String,
    deviceType: String,
    simulatorName: String,
    fixtureSet: String,
    artifacts: [ProofArtifact]
  ) {
    self.schemaVersion = schemaVersion
    self.runID = runID
    self.commit = commit
    self.createdAt = createdAt
    self.command = command
    self.platform = platform
    self.scheme = scheme
    self.bundleIdentifier = bundleIdentifier
    self.runtime = runtime
    self.deviceType = deviceType
    self.simulatorName = simulatorName
    self.fixtureSet = fixtureSet
    self.artifacts = artifacts
  }
}

enum BrowserJourneyContract {
  static let testIdentifier =
    "PutioUITests/FilesBrowserJourneyTests/testRunnableAlphaLoop"
  static let unsupportedFileTestIdentifier =
    "PutioUITests/FilesBrowserJourneyTests/testUnsupportedFileIsNotActionable"
  static let resumePersistenceTestIdentifier =
    "PutioUITests/FilesBrowserJourneyTests/testPlaybackPositionPersistsAcrossReopen"
  static let fileActionsTestIdentifier =
    "PutioUITests/FilesBrowserJourneyTests/testFileActionsCreateRenameRollbackRetryAndTrash"
  static let trashDisabledTestIdentifier =
    "PutioUITests/FilesBrowserJourneyTests/testTrashDisabledUsesPermanentDeleteCopyAndVisibleMenu"
  static let fileActionsAttachmentName = "runtime-file-actions"
  static let signOutRecoveryTestIdentifier =
    "PutioUITests/FilesBrowserJourneyTests/testSignOutFailureRecoversWithExplicitRetry"
  static let signOutFailureAttachmentName = "runtime-sign-out-failure"
  static let attachmentNames = [
    "runtime-sign-in",
    "runtime-playback",
    "runtime-signed-out",
  ]

  static func artifactFileName(for attachmentName: String) -> String {
    "\(attachmentName).png"
  }
}

private struct XCResultAttachmentGroup: Decodable {
  let attachments: [XCResultAttachment]
}

private struct XCResultAttachment: Decodable {
  let exportedFileName: String
  let suggestedHumanReadableName: String
}

struct XCResultTestSummary: Decodable, Equatable, Sendable {
  let result: String
  let totalTestCount: Int
  let passedTests: Int
  let failedTests: Int
  let skippedTests: Int
  let expectedFailures: Int
}

func selectJourneyAttachmentFiles(
  from manifestData: Data,
  expectedNames: [String] = BrowserJourneyContract.attachmentNames
) throws -> [String: String] {
  let groups: [XCResultAttachmentGroup]
  do {
    groups = try JSONDecoder().decode([XCResultAttachmentGroup].self, from: manifestData)
  } catch {
    throw HarnessFailure("decode XCUITest attachment manifest: \(error)")
  }
  let attachments = groups.flatMap(\.attachments)
  var selected: [String: String] = [:]
  for name in expectedNames {
    let matches = attachments.filter {
      matchesJourneyAttachmentName(
        suggestedName: $0.suggestedHumanReadableName,
        expectedName: name
      )
    }
    guard matches.count == 1, let match = matches.first else {
      throw HarnessFailure(
        "XCUITest attachment \(name) must appear exactly once; found \(matches.count)"
      )
    }
    let exportedName = match.exportedFileName
    guard !exportedName.isEmpty,
      URL(fileURLWithPath: exportedName).lastPathComponent == exportedName,
      URL(fileURLWithPath: exportedName).pathExtension.lowercased() == "png"
    else {
      throw HarnessFailure("XCUITest attachment \(name) has an invalid exported PNG filename")
    }
    selected[name] = exportedName
  }
  return selected
}

private func matchesJourneyAttachmentName(
  suggestedName: String,
  expectedName: String
) -> Bool {
  if suggestedName == expectedName { return true }
  let prefix = expectedName + "_"
  let suffix = ".png"
  guard suggestedName.hasPrefix(prefix), suggestedName.lowercased().hasSuffix(suffix) else {
    return false
  }
  let metadataStart = suggestedName.index(suggestedName.startIndex, offsetBy: prefix.count)
  let metadataEnd = suggestedName.index(suggestedName.endIndex, offsetBy: -suffix.count)
  let metadata = suggestedName[metadataStart..<metadataEnd]
  let components = metadata.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
  guard components.count == 2,
    let ordinal = Int(components[0]),
    ordinal >= 0,
    UUID(uuidString: String(components[1])) != nil
  else {
    return false
  }
  return true
}

@discardableResult
func requirePassingJourneySummary(_ summaryData: Data) throws -> XCResultTestSummary {
  let summary: XCResultTestSummary
  do {
    summary = try JSONDecoder().decode(XCResultTestSummary.self, from: summaryData)
  } catch {
    throw HarnessFailure("decode XCUITest result summary: \(error)")
  }
  guard summary.result == "Passed",
    summary.totalTestCount == 1,
    summary.passedTests == 1,
    summary.failedTests == 0,
    summary.skippedTests == 0,
    summary.expectedFailures == 0
  else {
    throw HarnessFailure(
      "browser journey must pass exactly 1 of 1 tests with no failures or skips; "
        + "result=\(summary.result), total=\(summary.totalTestCount), "
        + "passed=\(summary.passedTests), failed=\(summary.failedTests), "
        + "skipped=\(summary.skippedTests), expectedFailures=\(summary.expectedFailures)"
    )
  }
  return summary
}

public struct HarnessFailure: Error, CustomStringConvertible, Sendable {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }

  public var description: String { message }
}
