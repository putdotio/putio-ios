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
          SnapshotSuite(scheme: "PutioTV", target: "PutioTVSnapshotTests"),
          SnapshotSuite(scheme: "PutioTVFeatureTests", target: "PutioTVFeatureTests"),
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
  case deviceSignIn = "device-sign-in"
  case liveFilesBrowser = "live-files-browser"
  case liveDeviceSignIn = "live-device-sign-in"

  var fixtureSet: String {
    switch self {
    case .filesBrowser: "seeded-runtime-loop-v5"
    case .deviceSignIn: "seeded-device-sign-in-v1"
    case .liveFilesBrowser: "live-devs-auto-fixture-folder-v1"
    case .liveDeviceSignIn: "live-devs-auto-device-code-v1"
    }
  }

  public var platform: HarnessPlatform {
    switch self {
    case .filesBrowser, .liveFilesBrowser: .ios
    case .deviceSignIn, .liveDeviceSignIn: .tvos
    }
  }

  /// Live scenarios sign in to the devs-auto account; the rest are seeded.
  public var isLive: Bool {
    self == .liveFilesBrowser || self == .liveDeviceSignIn
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
    output: OutputFormat,
    device: String? = nil
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
}

enum LiveFixtureContract {
  static let profile = "devs-auto"
  static let rootFolder = "putio-ios-harness"
  static let previewFile = "live-fixture.png"
  static let previewFileType = "IMAGE"
  /// Repository path of the image uploaded as `previewFile`.
  static let previewSource = "Tests/HarnessMedia/previews/runtime-proof-image.png"
}

/// The DEBUG-only contract between a live harness run and the app it drives,
/// mirrored by `HarnessLiveSession` in Apps/Shared. Both files live in the
/// app's data container `tmp` directory.
enum LiveSessionContract {
  static let scenario = "live"
  static let signOutArgument = "--putio-harness-live-sign-out"
  static let deviceCodeFile = "tmp/putio-harness-device-code"
  static let outcomeFile = "tmp/putio-harness-live-session"
  static let revokedFile = "tmp/putio-harness-live-revoked"
  static let testEnvironment = "TEST_RUNNER_PUTIO_HARNESS_LIVE"
  static let folderEnvironment = "TEST_RUNNER_PUTIO_HARNESS_LIVE_FOLDER_ID"
  static let fileEnvironment = "TEST_RUNNER_PUTIO_HARNESS_LIVE_FILE_ID"

  /// A put.io activation code as the app displays it. Anything else in the
  /// probe file is refused before it reaches the CLI.
  static func deviceCode(from data: Data) -> String? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard code.range(of: #"^[A-Za-z0-9]{4,16}$"#, options: .regularExpression) != nil else {
      return nil
    }
    return code
  }

  enum Outcome: String, Equatable, Sendable {
    /// The cleanup launch found no saved token. On its own this proves
    /// nothing: the token may never have been saved, or lived only in the
    /// killed process.
    case noSession = "no-session"
    /// The cleanup launch restored a saved token and revoked it.
    case signedOut = "signed-out"
    /// put.io rejected the saved token.
    case expired
    case restoreFailed = "restore-failed"
    case signOutFailed = "sign-out-failed"

    /// Failures that leave the token in the keychain, so another launch can retry.
    var isRetryable: Bool { self == .restoreFailed || self == .signOutFailed }
  }

  static func outcome(from data: Data) -> Outcome? {
    String(data: data, encoding: .utf8).flatMap {
      Outcome(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }
}

/// What the cleanup launch established about the run's grant.
struct LiveCleanup: Equatable, Sendable {
  let outcome: LiveSessionContract.Outcome
  /// The app wrote its revocation marker, which it does only after put.io
  /// revoked or rejected the token, in this or an earlier launch.
  let revocationRecorded: Bool

  /// Only positive evidence counts: an absent token is not a revoked one.
  var isRevoked: Bool {
    switch outcome {
    case .signedOut, .expired: true
    case .noSession: revocationRecorded
    case .restoreFailed, .signOutFailed: false
    }
  }

  var summary: String {
    let detail =
      outcome != .noSession
      ? "" : revocationRecorded ? " after a recorded revocation" : " with no recorded revocation"
    let base = "cleanup launch reported \(outcome.rawValue)\(detail)"
    return isRevoked ? base : "\(base); \(Self.possiblyLive)"
  }

  static let possiblyLive =
    "the run's grant may still be live on the \(LiveFixtureContract.profile) account. "
    + "Revoke put.io iOS from that account's apps in put.io settings; this also signs out "
    + "its other put.io iOS and Apple TV sessions"
}

/// Repeats a cleanup launch while the token may still be saved: after a
/// failed launch, a timed-out report, or a failed restore or sign-out. Stops
/// once revocation is proven or the app reports it has no token.
func retryLiveCleanup(
  attempts: Int, delay: TimeInterval, _ attempt: () throws -> LiveCleanup
) throws -> LiveCleanup {
  var failures: [String] = []
  var last: LiveCleanup?
  for number in 1...attempts {
    if number > 1 { Thread.sleep(forTimeInterval: delay) }
    do {
      let cleanup = try attempt()
      last = cleanup
      if cleanup.isRevoked || !cleanup.outcome.isRetryable { return cleanup }
      failures.append("attempt \(number): \(cleanup.outcome.rawValue)")
    } catch {
      failures.append("attempt \(number): \(error)")
    }
  }
  if let last { return last }
  throw HarnessFailure(
    "live cleanup launch failed \(attempts) times\n" + failures.joined(separator: "\n"))
}

/// Runs the live cleanup launch at most until it proves revocation. The
/// journey and the interrupt handler share one instance, so whichever runs
/// second reuses a proven result or retries a failed one.
final class LiveRevocation: @unchecked Sendable {
  private let lock = NSLock()
  private let attempt: () throws -> LiveCleanup
  private var proven: LiveCleanup?

  init(_ attempt: @escaping () throws -> LiveCleanup) {
    self.attempt = attempt
  }

  func run() throws -> LiveCleanup {
    try lock.withLock {
      if let proven { return proven }
      let cleanup = try attempt()
      if cleanup.isRevoked { proven = cleanup }
      return cleanup
    }
  }

  /// Interrupt-time cleanup: fails loudly unless revocation is proven.
  func requireRevoked() throws {
    let cleanup: LiveCleanup
    do {
      cleanup = try run()
    } catch {
      throw HarnessFailure("live revocation failed: \(error); \(LiveCleanup.possiblyLive)")
    }
    guard cleanup.isRevoked else { throw HarnessFailure("live session: \(cleanup.summary)") }
  }
}

enum LiveFilesJourneyContract {
  static let testIdentifier =
    "PutioUITests/LiveFilesJourneyTests/testSignInOpenFixtureFolderPreviewAndSignOut"
  static let attachmentNames = [
    "live-signed-in", "live-fixture-folder", "live-preview", "live-authorized-apps",
    "live-signed-out",
  ]
}

enum LiveDeviceSignInJourneyContract {
  static let testIdentifier =
    "PutioTVUITests/LiveDeviceSignInJourneyTests/testApprovedCodeSignsInAndSignOutRevokes"
  static let attachmentNames = ["live-tv-sign-in-code", "live-tv-account", "live-tv-signed-out"]
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
  /// Absent from schema 2 physical-device manifests, whose hardware is
  /// `deviceType`; schema 1 simulator manifests always carry it.
  public let simulatorName: String?
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
    simulatorName: String?,
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

enum DeviceSignInJourneyContract {
  static let testIdentifier =
    "PutioTVUITests/DeviceSignInJourneyTests/testCodeExpiryApprovalRelaunchAndSignOut"
  static let attachmentNames = [
    "runtime-tv-sign-in-code", "runtime-tv-sign-in-expired", "runtime-tv-account",
  ]
}

enum BrowserJourneyContract {
  static let accessibilityFilesTestIdentifier =
    "PutioUITests/AccessibilityJourneyTests/testLongNamesSelectionAndDownloadPickerAtLargestTextSize"
  static let accessibilityAudioTestIdentifier =
    "PutioUITests/AccessibilityJourneyTests/testAudioSliderAndControlsAtLargestTextSizeInBothOrientations"
  static let accessibilityFilesAttachmentNames = [
    "runtime-accessibility-files", "runtime-accessibility-selection",
    "runtime-accessibility-downloads", "runtime-accessibility-download-picker",
  ]
  static let accessibilityAudioAttachmentNames = [
    "runtime-accessibility-audio-portrait", "runtime-accessibility-audio-landscape",
    "runtime-accessibility-audio-portrait-controls",
    "runtime-accessibility-audio-landscape-controls",
  ]
  static let testIdentifier =
    "PutioUITests/FilesBrowserJourneyTests/testRunnableAlphaLoop"
  static let downloadsTestIdentifier =
    "PutioUITests/DownloadsJourneyTests/testMultiAudioDownloadOfflinePlaybackAndPositionSync"
  static let downloadsAttachmentNames = [
    "runtime-downloads-picker", "runtime-downloads-queue", "runtime-downloads-detail",
    "runtime-downloads-remove",
  ]
  static let castTestIdentifier =
    "PutioUITests/ChromecastJourneyTests/testCastSettingsSessionControlsSubtitlesAndPositionSync"
  static let castAttachmentNames = [
    "runtime-cast-settings", "runtime-cast-error", "runtime-cast-controls",
    "runtime-cast-signed-out",
  ]
  static let previewsTestIdentifier =
    "PutioUITests/PreviewJourneyTests/testImagePDFUnsupportedAndVLCHandoffOutcomes"
  static let previewsAttachmentNames = [
    "runtime-preview-image", "runtime-preview-document", "runtime-preview-error",
    "runtime-preview-unsupported", "runtime-vlc-missing",
  ]
  static let resumePersistenceTestIdentifier =
    "PutioUITests/FilesBrowserJourneyTests/testPlaybackPositionPersistsAcrossReopen"
  static let fileActionsTestIdentifier =
    "PutioUITests/FilesBrowserJourneyTests/testFileActionsCreateRenameRollbackRetryAndTrash"
  static let trashDisabledTestIdentifier =
    "PutioUITests/FilesBrowserJourneyTests/testTrashDisabledUsesPermanentDeleteCopyInContextMenu"
  static let trashManagementTestIdentifier =
    "PutioUITests/FilesBrowserJourneyTests/testTrashManagementRestoreRetryDeleteAndEmpty"
  static let sortAndContinuationTestIdentifier =
    "PutioUITests/FilesBrowserJourneyTests/testSortRoundTripAndContinuationAppendsTheSecondPage"
  static let searchAndRestorationTestIdentifier =
    "PutioUITests/FilesBrowserJourneyTests/testSearchPaginationRetryAndFolderRestoration"
  static let folderReconciliationTestIdentifier =
    "PutioUITests/FilesBrowserJourneyTests/testRenamingAndDeletingOpenFolderReconcilesOtherTabs"
  static let accountRatingTestIdentifier =
    "PutioUITests/AccountJourneyTests/testRatingLinkOpensReviewPageOnlyAfterExplicitTap"
  static let accountRatingAttachmentName = "runtime-account-rating"
  static let audioTestIdentifier =
    "PutioUITests/AudioJourneyTests/testAudioPlaysPausesChangesSpeedAndAdvancesToTheNextTrack"
  static let audioAttachmentName = "runtime-audio-player"
  static let playbackPreferencesTestIdentifier =
    "PutioUITests/PlaybackPreferencesJourneyTests/testProxySubtitlesAndAutoplayRetryAndPersistAcrossRelaunch"
  static let playbackPreferencesAttachmentName = "runtime-playback-preferences"
  static let accountSecurityTestIdentifier =
    "PutioUITests/AccountSecurityJourneyTests/testTwoFactorAppsLinkingClearDataAndDestroy"
  static let accountSecurityAttachmentNames = [
    "runtime-security-recovery-codes", "runtime-security-apps", "runtime-danger-clear-data",
  ]
  static let deepLinksTestIdentifier =
    "PutioUITests/DeepLinkJourneyTests/testColdWarmAndSignedOutLinksUseExistingScreens"
  static let deepLinksAttachmentNames = [
    "runtime-deep-link-loading", "runtime-deep-link-error", "runtime-deep-link-folder",
  ]
  static let filePreferencesTestIdentifier =
    "PutioUITests/FilePreferencesJourneyTests/testFilePreferencesFailureRecoveryResetAndPersistence"
  static let filePreferencesAttachmentNames = [
    "runtime-file-preferences", "runtime-file-preferences-refresh",
  ]
  static let historyTestIdentifier =
    "PutioUITests/HistoryJourneyTests/testHistoryPagingNavigationMutationsAndSettingGate"
  static let historyAttachmentNames = [
    "runtime-history-loaded", "runtime-history-error", "runtime-history-empty",
  ]
  static let searchResultsAttachmentName = "runtime-search-results"
  static let sortedRootAttachmentName = "runtime-sorted-root"
  static let fileActionsAttachmentName = "runtime-file-actions"
  static let signOutRecoveryTestIdentifier =
    "PutioUITests/FilesBrowserJourneyTests/testSignOutFailureRecoversWithExplicitRetry"
  static let signOutFailureAttachmentName = "runtime-sign-out-failure"
  static let trashManagementAttachmentNames = [
    "runtime-trash-refresh-error", "runtime-trash-loaded", "runtime-trash-empty",
  ]
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
