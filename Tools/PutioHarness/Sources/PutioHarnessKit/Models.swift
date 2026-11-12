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
        testPlan: TestPlan(
          name: "Putio", targets: ["PutioSnapshotTests", "PutioFeatureTests", "PutioUITests"]),
        journeyTestPlan: "PutioJourneys"
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
        testPlan: TestPlan(
          name: "PutioTV", targets: ["PutioTVSnapshotTests", "PutioTVFeatureTests"]),
        journeyTestPlan: "PutioTVJourneys"
      )
    }
  }
}

public struct TestPlan: Equatable, Sendable {
  public let name: String
  public let targets: [String]

  public init(name: String, targets: [String]) {
    self.name = name
    self.targets = targets
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
  public let testPlan: TestPlan?
  public let journeyTestPlan: String?

  public init(
    scheme: String,
    bundleIdentifier: String,
    sdk: String,
    destination: String,
    productDirectory: String,
    appName: String,
    runtimePlatform: String,
    deviceFamily: String,
    testPlan: TestPlan? = nil,
    journeyTestPlan: String? = nil
  ) {
    self.scheme = scheme
    self.bundleIdentifier = bundleIdentifier
    self.sdk = sdk
    self.destination = destination
    self.productDirectory = productDirectory
    self.appName = appName
    self.runtimePlatform = runtimePlatform
    self.deviceFamily = deviceFamily
    self.testPlan = testPlan
    self.journeyTestPlan = journeyTestPlan
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
    case .deviceSignIn: "seeded-device-sign-in-v4"
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
    only: [String] = [],
    output: OutputFormat
  )
  case boards(
    ids: [String], xxl: Bool = false, device: BoardDevice? = nil, runID: String?,
    output: OutputFormat)
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

/// One live run's grant, shared by the journey and the interrupt handler.
/// Every transition happens under one lock:
///
///     idle ── approve ──▶ approved ── revoke ──▶ finished
///       └──── revoke ───▶ cancelled
///
/// The approval write runs inside `approve`, so revocation either waits for
/// it or has already cancelled it; no approval can start once revocation has.
/// Revocation runs once, with its own retries, and later callers reuse its
/// result, so the interrupt handler never retries alongside a teardown.
final class LiveGrant: @unchecked Sendable {
  private enum State {
    case idle
    case approved
    case cancelled
    case finished(Result<LiveCleanup, Error>)
  }

  private let lock = NSLock()
  private let revokeAttempts: () throws -> LiveCleanup
  private var state = State.idle

  init(revoke: @escaping () throws -> LiveCleanup) {
    revokeAttempts = revoke
  }

  /// Runs the approval write unless cleanup has already started. A failed
  /// write still counts as approved: put.io may have linked the grant.
  func approve(_ write: () throws -> Void) throws {
    try lock.withLock {
      guard case .idle = state else {
        throw HarnessFailure("live approval refused: harness cleanup already started")
      }
      state = .approved
      try write()
    }
  }

  /// The cleanup result, or nil when no approval write ever started.
  func revoke() throws -> LiveCleanup? {
    try lock.withLock {
      switch state {
      case .idle, .cancelled:
        state = .cancelled
        return nil
      case .finished(let result):
        return try result.get()
      case .approved:
        let result = Result { try revokeAttempts() }
        state = .finished(result)
        return try result.get()
      }
    }
  }

  /// Interrupt-time cleanup: fails loudly unless nothing was approved or
  /// revocation is proven.
  func requireRevoked() throws {
    let cleanup: LiveCleanup?
    do {
      cleanup = try revoke()
    } catch {
      throw HarnessFailure("live revocation failed: \(error); \(LiveCleanup.possiblyLive)")
    }
    if let cleanup, !cleanup.isRevoked {
      throw HarnessFailure("live session: \(cleanup.summary)")
    }
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

public enum BoardDevice: String, CaseIterable, Codable, Sendable {
  case iphone
  case ipad
  case duoFolded = "duo-folded"
  case duoOpen = "duo-open"

  var deviceFamily: String {
    switch self {
    case .iphone, .duoFolded, .duoOpen: "iPhone"
    case .ipad: "iPad"
    }
  }

  var deviceType: String {
    switch self {
    case .iphone: "iPhone 17 Pro"
    case .ipad: "iPad Pro 11-inch (M5)"
    case .duoFolded, .duoOpen: "iPhone Duo"
    }
  }

  var requiredDeviceTypeIdentifier: String? {
    switch self {
    case .iphone, .ipad: nil
    case .duoFolded, .duoOpen: foldableDeviceTypeIdentifier
    }
  }
}

struct BoardCapture: Equatable, Sendable {
  let id: String
  private(set) var device: BoardDevice
  let testIdentifier: String
  let isScreenBase: Bool
  let environment: [String: String]

  init(
    _ id: String, _ device: BoardDevice, _ testIdentifier: String, screenBase: Bool = true,
    environment: [String: String] = [:]
  ) {
    self.id = id
    self.device = device
    self.testIdentifier = "PutioUITests/BoardCaptureTests/" + testIdentifier
    isScreenBase = screenBase
    self.environment = environment
  }

  static func gallery(_ page: String, _ device: BoardDevice) -> BoardCapture {
    let id = device == .iphone ? "gallery-\(page)" : "gallery-\(page)-\(device.rawValue)"
    return BoardCapture(
      id, device, "testGalleryPage",
      environment: ["PUTIO_BOARD_ID": id, "PUTIO_GALLERY_PAGE": page])
  }

  var layoutAttachmentName: String { "\(id)-layout" }

  var testEnvironment: [String: String] {
    environment.merging(
      ["PUTIO_BOARD_ID": id, "PUTIO_BOARD_DEVICE": device.rawValue]
    ) { declared, _ in declared }
  }

  func on(_ device: BoardDevice) -> BoardCapture {
    var capture = self
    capture.device = device
    return capture
  }
}

enum BoardCaptureContract {
  static let fixtureSet = "seeded-runtime-loop-v5"

  static let boards =
    [
      BoardCapture("rd-ios-02-folder", .iphone, "testFolder"),
      BoardCapture("rd-ios-05-more", .iphone, "testMoreMenu"),
      BoardCapture("rd-ios-20-rename", .iphone, "testRename"),
      BoardCapture("rd-ios-21-new-folder", .iphone, "testNewFolder"),
      BoardCapture("rd-ios-77-rename-failed-toast", .iphone, "testRenameFailedToast"),
      BoardCapture("rd-ios-04-sort", .iphone, "testSortMenu"),
      BoardCapture("rd-ios-72-sorting", .iphone, "testSortingUpdate"),
      BoardCapture("rd-ios-12-ipad-split", .ipad, "testIPadSplit"),
      BoardCapture("rd-ios-08-empty", .iphone, "testEmptyFolder"),
      BoardCapture("rd-ios-32-load-more-failed", .iphone, "testFolderLoadMoreFailed"),
      BoardCapture("rd-ios-40-loading", .iphone, "testFolderLoading"),
      BoardCapture("rd-ios-41-loading-more", .iphone, "testFolderLoadingMore"),
      BoardCapture("rd-ios-09-error", .iphone, "testFolderLoadFailed"),
      BoardCapture("rd-ios-43-offline", .iphone, "testFolderOffline"),
      BoardCapture("rd-ios-44-no-access", .iphone, "testFolderNoAccess"),
      BoardCapture("rd-ios-74-rate-limited", .iphone, "testFolderRateLimited"),
      BoardCapture("rd-ios-75-unavailable", .iphone, "testFolderUnavailable"),
      BoardCapture("rd-ios-03-row-actions", .iphone, "testRowActions"),
      BoardCapture("rd-ios-11-swipe", .iphone, "testSwipeActions"),
      BoardCapture("rd-ios-17-folder-long-press", .iphone, "testFolderLongPress"),
      BoardCapture("rd-ios-63-file-menu", .iphone, "testFileMenu"),
      BoardCapture("rd-ios-64-vlc-menu", .iphone, "testVLCMenu"),
      BoardCapture("rd-ios-10-trashed", .iphone, "testTrashed"),
      BoardCapture("rd-ios-22-delete-permanently", .iphone, "testDeletePermanently"),
      BoardCapture("rd-ios-51-trash-off-menu", .iphone, "testTrashOffMenu"),
      BoardCapture("rd-ios-52-trash-unknown-menu", .iphone, "testTrashUnknownMenu"),
      BoardCapture("rd-ios-53-trash-limit", .iphone, "testTrashLimit"),
      BoardCapture("rd-ios-19-move", .iphone, "testMove"),
      BoardCapture("rd-ios-35-move-folder", .iphone, "testMoveFolder", screenBase: false),
      BoardCapture("rd-ios-36-move-loading", .iphone, "testMoveLoading", screenBase: false),
      BoardCapture(
        "rd-ios-37-move-current-folder", .iphone, "testMoveCurrentFolder", screenBase: false),
      BoardCapture("rd-ios-38-move-failed", .iphone, "testMoveNameTaken"),
      BoardCapture("rd-ios-39-moved", .iphone, "testMoved", screenBase: false),
      BoardCapture(
        "rd-ios-69-move-into-itself", .iphone, "testMoveIntoItself", screenBase: false),
      BoardCapture("Main", .iphone, "testFilesRoot"),
      BoardCapture(
        "rd-ios-hist-13-tab-hidden", .iphone, "testHistoryTabHidden", screenBase: false),
      BoardCapture("rd-ios-13-ipad-sidebar", .ipad, "testIPadSidebar"),
      BoardCapture("rd-ios-14-ipad-portrait", .ipad, "testIPadPortrait"),
      BoardCapture(
        "gallery-split-ipad-none", .ipad, "testListDetailNothingSelected", screenBase: false),
      BoardCapture(
        "gallery-split-ipad-detail", .ipad, "testListDetailKeepsSelectionAcrossRotation",
        screenBase: false),
      BoardCapture("rd-ios-duo-01-folded-folder", .duoFolded, "testFolder"),
      BoardCapture("rd-ios-duo-02-open-folder", .duoOpen, "testFolder"),
      BoardCapture("rd-ios-ses-01-welcome", .iphone, "testWelcome"),
      BoardCapture(
        "rd-ios-ses-02-welcome-frame-2", .iphone, "testWelcomeSecondFrame", screenBase: false),
      BoardCapture("rd-ios-ses-04-waiting", .iphone, "testCheckingSession", screenBase: false),
      BoardCapture("rd-ios-ses-05-failed", .iphone, "testSignInFailed"),
      BoardCapture("rd-ios-ses-06-expired", .iphone, "testSessionExpired"),
      BoardCapture("rd-ios-ses-07-storage", .iphone, "testSecureStorageUnavailable"),
      BoardCapture("rd-ios-ses-13-restoring", .iphone, "testRestoring"),
      BoardCapture(
        "rd-ios-ses-14-check-failed", .iphone, "testSessionCheckFailed", screenBase: false),
      BoardCapture("rd-ios-ses-15-signing-out", .iphone, "testSigningOut", screenBase: false),
      BoardCapture("rd-ios-ses-08-sign-out", .iphone, "testSignOutWithDownloads"),
      BoardCapture(
        "rd-ios-ses-16-sign-out-no-downloads", .iphone, "testSignOutWithoutDownloads"),
      BoardCapture("rd-ios-ses-24-ipad-sign-out", .ipad, "testSignOutWithDownloads"),
      BoardCapture("rd-ios-ses-11-ipad-welcome", .ipad, "testWelcome"),
      BoardCapture("rd-ios-ses-12-ipad-failed", .ipad, "testSignInFailed", screenBase: false),
      BoardCapture(
        "rd-ios-ses-22-ipad-check-failed", .ipad, "testSessionCheckFailed", screenBase: false),
      BoardCapture(
        "rd-ios-ses-23-ipad-storage", .ipad, "testSecureStorageUnavailable", screenBase: false),
      BoardCapture("rd-ios-ses-27-duo-closed-welcome", .duoFolded, "testWelcome"),
      BoardCapture(
        "rd-ios-ses-28-duo-closed-waiting", .duoFolded, "testCheckingSession", screenBase: false),
      BoardCapture("rd-ios-ses-29-duo-open-welcome", .duoOpen, "testWelcome"),
      BoardCapture("rd-ios-pv-01-image", .iphone, "testPreviewImage"),
      BoardCapture("rd-ios-pv-02-more", .iphone, "testPreviewMoreMenu"),
      BoardCapture("rd-ios-pv-03-pdf", .iphone, "testPreviewDocument"),
      BoardCapture("rd-ios-pv-04-text", .iphone, "testPreviewText"),
      BoardCapture("rd-ios-pv-05-unsupported", .iphone, "testPreviewCannotShow"),
      BoardCapture("rd-ios-pv-07-loading", .iphone, "testPreviewLoading", screenBase: false),
      BoardCapture("rd-ios-pv-08-error", .iphone, "testPreviewError"),
      BoardCapture("rd-ios-pv-09-position", .iphone, "testPreviewPosition"),
      BoardCapture("rd-ios-pv-10-text-truncated", .iphone, "testPreviewTextTruncated"),
      BoardCapture("rd-ios-pv-13-landscape-image", .iphone, "testPreviewLandscapeImage"),
      BoardCapture("rd-ios-pv-20-rename", .iphone, "testPreviewRename"),
      BoardCapture("rd-ios-pv-17-duo-folded-image", .duoFolded, "testPreviewImage"),
      BoardCapture("rd-ios-pv-16-duo-image", .duoOpen, "testPreviewImage"),
      BoardCapture("rd-ios-acc-01-downloads", .iphone, "testAccountDownloads"),
      BoardCapture("rd-ios-acc-02-account", .iphone, "testAccountTop"),
      BoardCapture(
        "rd-ios-acc-03-account-middle", .iphone, "testAccountPlayback", screenBase: false),
      BoardCapture(
        "rd-ios-acc-22-account-security", .iphone, "testAccountSecurity", screenBase: false),
      BoardCapture("rd-ios-acc-04-account-end", .iphone, "testAccountEnd", screenBase: false),
      BoardCapture("rd-ios-ses-10-analytics", .iphone, "testAnalyticsPrompt"),
      BoardCapture(
        "rd-ios-ses-17-analytics-saving", .iphone, "testAnalyticsPromptSaving", screenBase: false),
      BoardCapture(
        "rd-ios-ses-18-analytics-failed", .iphone, "testAnalyticsPromptFailed", screenBase: false),
      BoardCapture("rd-ios-ses-25-ipad-analytics", .ipad, "testIPadAnalyticsPrompt"),
      BoardCapture(
        "rd-ios-ses-19-inactive", .iphone, "testInactiveNotice",
        environment: ["PUTIO_INACTIVE_ACCOUNT": "owner"]),
      BoardCapture(
        "rd-ios-ses-20-inactive-no-date", .iphone, "testInactiveNotice", screenBase: false,
        environment: ["PUTIO_INACTIVE_ACCOUNT": "owner-no-date"]),
      BoardCapture(
        "rd-ios-ses-21-inactive-family", .iphone, "testInactiveNotice", screenBase: false,
        environment: ["PUTIO_INACTIVE_ACCOUNT": "family"]),
      BoardCapture(
        "rd-ios-ses-26-ipad-inactive", .ipad, "testIPadInactiveNotice",
        environment: ["PUTIO_INACTIVE_ACCOUNT": "owner"]),
      BoardCapture("rd-ios-acc-26-settings-loading", .iphone, "testAccountSettingsLoading"),
      BoardCapture("rd-ios-acc-27-settings-failed", .iphone, "testAccountSettingsFailed"),
      BoardCapture("rd-ios-acc-21-save-failed", .iphone, "testAccountSaveFailed"),
      BoardCapture("rd-ios-acc-28-storage-full", .iphone, "testAccountStorageFull"),
      BoardCapture("rd-ios-acc-05-default-sort", .iphone, "testAccountDefaultSort"),
      BoardCapture("rd-ios-acc-23-reset-sort", .iphone, "testAccountResetSort"),
      BoardCapture("rd-ios-acc-24-trash-off", .iphone, "testAccountTrashOff"),
      BoardCapture("rd-ios-acc-59-trash-off-account", .iphone, "testAccountWithTrashOff"),
      BoardCapture("rd-ios-acc-60-resume-off-confirm", .iphone, "testAccountResumeOff"),
      BoardCapture("rd-ios-acc-08-privacy", .iphone, "testAccountPrivacy"),
      BoardCapture("rd-ios-acc-25-history-off", .iphone, "testAccountHistoryOff"),
      BoardCapture("rd-ios-acc-06-playback-method", .iphone, "testAccountPlaybackMethod"),
      BoardCapture("rd-ios-acc-07-proxy", .iphone, "testAccountProxy"),
      BoardCapture("rd-ios-acc-31-proxy-loading", .iphone, "testAccountProxyLoading"),
      BoardCapture("rd-ios-acc-32-proxy-failed", .iphone, "testAccountProxyFailed"),
      BoardCapture("rd-ios-acc-33-proxy-unavailable", .iphone, "testAccountProxyUnavailable"),
      BoardCapture(
        "rd-ios-acc-29-inactive", .iphone, "testAccountInactive",
        environment: ["PUTIO_INACTIVE_ACCOUNT": "owner"]),
      BoardCapture(
        "rd-ios-acc-30-inactive-family", .iphone, "testAccountInactive", screenBase: false,
        environment: ["PUTIO_INACTIVE_ACCOUNT": "family"]),
    ] + galleryPages.flatMap { page in galleryDevices.map { .gallery(page, $0) } }

  static let galleryDevices: [BoardDevice] = [.iphone, .ipad]

  static let galleryPages = [
    "buttons", "files", "states", "feedback", "forms", "sheets", "shell", "menus", "text-alert",
    "confirm-alert", "selection-none", "selection-some", "selection-all", "split",
  ]

  static func resolve(_ ids: [String], device: BoardDevice? = nil) throws -> [BoardCapture] {
    guard !ids.isEmpty else { throw HarnessFailure("--boards needs at least one board id") }
    let unknown = ids.filter { id in !boards.contains { $0.id == id } }
    guard unknown.isEmpty else {
      throw HarnessFailure(
        "no board table entry for \(unknown.joined(separator: ", ")); known boards: "
          + boards.map(\.id).joined(separator: ", "))
    }
    guard Set(ids).count == ids.count else {
      throw HarnessFailure("--boards lists a board id twice")
    }
    return ids.compactMap { id in boards.first { $0.id == id } }.map { capture in
      device.map(capture.on) ?? capture
    }
  }
}

struct BoardLayout: Codable, Equatable, Sendable {
  let width: Double
  let height: Double
  let scale: Double
}

public enum BoardTextSize: String, Codable, Sendable {
  case standard
  case xxl

  var contentSizeCategory: String {
    switch self {
    case .standard: "large"
    case .xxl: "extra-extra-large"
    }
  }
}

public struct BoardArtifact: Codable, Equatable, Sendable {
  public let board: String
  public let device: BoardDevice
  public let textSize: BoardTextSize
  public let deviceType: String
  public let pointWidth: Double
  public let pointHeight: Double
  public let path: String
  public let sha256: String
}

public struct BoardManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let runID: String
  public let commit: String
  public let createdAt: String
  public let command: String
  public let runtime: String
  public let fixtureSet: String
  public let boards: [BoardArtifact]
}

enum DeviceSignInJourneyContract {
  static let testIdentifier =
    "PutioTVUITests/DeviceSignInJourneyTests/testCodeExpiryApprovalRelaunchAndSignOut"
  static let attachmentNames = [
    "runtime-tv-sign-in-code", "runtime-tv-sign-in-expired", "runtime-tv-account",
  ]
}

/// The signed-in TV surfaces: Home, History, Account, and Trash, each with
/// its modal, empty, and recovery states.
enum TVAccountJourneyContract {
  static let historyTrashTestIdentifier =
    "PutioTVUITests/AccountHistoryTrashJourneyTests/testHistoryAndTrashModalsEmptyStatesAndRecovery"
  static let historyTrashAttachmentNames = [
    "runtime-tv-home", "runtime-tv-history-recovery", "runtime-tv-history-open-failure",
    "runtime-tv-history-clear-modal", "runtime-tv-history-empty", "runtime-tv-home-history-off",
    "runtime-tv-account-settings", "runtime-tv-trash", "runtime-tv-trash-recovery",
    "runtime-tv-trash-modal", "runtime-tv-trash-empty",
  ]
  static let settingsTestIdentifier =
    "PutioTVUITests/AccountHistoryTrashJourneyTests/testSettingsCycleProxyChooserAndTrashToggle"
  static let settingsAttachmentNames = [
    "runtime-tv-proxy-failure", "runtime-tv-proxy-chooser", "runtime-tv-account-subtitles-off",
    "runtime-tv-trash-off-modal", "runtime-tv-account-about",
  ]
}

/// Your Files and Search on TV: browse, sort, paging, the long-press menu,
/// system search, and their empty, error, and recovery states.
enum TVBrowseJourneyContract {
  static let browseTestIdentifier =
    "PutioTVUITests/FilesSearchJourneyTests/testBrowseSortMenuAndRecovery"
  static let browseAttachmentNames = [
    "runtime-tv-home-files", "runtime-tv-files", "runtime-tv-files-more-recovery",
    "runtime-tv-files-sort", "runtime-tv-files-menu", "runtime-tv-files-action-failure",
    "runtime-tv-files-trashed", "runtime-tv-folder", "runtime-tv-file-unsupported",
    "runtime-tv-files-empty", "runtime-tv-files-error", "runtime-tv-files-recovered",
  ]
  static let searchTestIdentifier =
    "PutioTVUITests/FilesSearchJourneyTests/testSystemSearchEmptyErrorResultsAndMenu"
  static let searchAttachmentNames = [
    "runtime-tv-search-keyboard", "runtime-tv-search-empty", "runtime-tv-search-error",
    "runtime-tv-search-results", "runtime-tv-search-menu", "runtime-tv-search-delete-confirm",
  ]
}

/// TV playback: the pre-play resume decision, episodic continuation,
/// subtitle and speed controls in the system player, and the conversion
/// gate, against loopback HLS fixtures.
enum TVPlaybackJourneyContract {
  static let continuationTestIdentifier =
    "PutioTVUITests/PlaybackJourneyTests/testResumeChoicesAndEpisodicContinuation"
  static let continuationAttachmentNames = [
    "runtime-tv-playback-resume", "runtime-tv-playback-resume-start-over",
    "runtime-tv-playback-up-next", "runtime-tv-playback-successor-resume",
    "runtime-tv-playback-playing",
  ]
  static let controlsTestIdentifier =
    "PutioTVUITests/PlaybackJourneyTests/testSubtitleAndSpeedControlsKeepTheAudioTrack"
  static let controlsAttachmentNames = [
    "runtime-tv-playback-subtitles", "runtime-tv-playback-subtitle-selected",
    "runtime-tv-playback-speed",
  ]
  static let conversionTestIdentifier =
    "PutioTVUITests/PlaybackJourneyTests/testConversionGateThenResume"
  static let conversionAttachmentNames = [
    "runtime-tv-playback-conversion-failure", "runtime-tv-playback-converting",
    "runtime-tv-playback-converted-resume",
  ]
}

/// One XCUITest the iOS journey runs on its own before the recorded walk.
struct JourneyPreflight: Equatable, Sendable {
  /// Names the test's result bundle, `.<name>.xcresult`.
  let name: String
  let testIdentifier: String
  let attachmentNames: [String]
  /// XCTest's per-test execution allowance, in seconds.
  let timeAllowance: Int

  init(
    _ name: String, _ testIdentifier: String, attachmentNames: [String] = [],
    timeAllowance: Int = 60
  ) {
    self.name = name
    self.testIdentifier = "PutioUITests/" + testIdentifier
    self.attachmentNames = attachmentNames
    self.timeAllowance = timeAllowance
  }
}

enum BrowserJourneyContract {
  /// Run in order on one simulator; each launches the app from a clean state.
  static let preflights = [
    JourneyPreflight(
      "accessibility-files",
      "AccessibilityJourneyTests/testLongNamesSelectionAndDownloadPickerAtLargestTextSize",
      attachmentNames: [
        "runtime-accessibility-files", "runtime-accessibility-selection",
        "runtime-accessibility-downloads", "runtime-accessibility-download-picker",
      ],
      timeAllowance: 180),
    JourneyPreflight(
      "accessibility-audio",
      "AccessibilityJourneyTests/testAudioSliderAndControlsAtLargestTextSizeInBothOrientations",
      attachmentNames: [
        "runtime-accessibility-audio-portrait", "runtime-accessibility-audio-landscape",
        "runtime-accessibility-audio-portrait-controls",
        "runtime-accessibility-audio-landscape-controls",
      ],
      timeAllowance: 180),
    JourneyPreflight(
      "file-row-gallery", "FileRowGalleryTests/testTrailingControlsReportTheActionForTheirState"),
    JourneyPreflight(
      "item-menus", "ItemActionsGalleryTests/testLongPressAndSwipeMoreListTheSameItemsInOrder",
      attachmentNames: ["item-menu-long-press", "item-menu-swipe-more"]),
    JourneyPreflight(
      "text-alert-retry",
      "ItemActionsGalleryTests/testTextAlertFailureClosesAndTryAgainResendsTheSameName",
      attachmentNames: ["text-alert-failure-toast"]),
    JourneyPreflight(
      "selection-mode",
      "SelectionGalleryTests/testSelectionHeaderAndBarReplaceTheTabBarUntilClosed",
      attachmentNames: ["selection-mode-some", "selection-mode-all"], timeAllowance: 90),
    JourneyPreflight(
      "session-welcome-motion",
      "SessionWelcomeJourneyTests/testFramesRollAndReduceMotionHoldsFrameOne",
      attachmentNames: [
        "runtime-session-welcome-rolled", "runtime-session-welcome-reduce-motion",
      ],
      timeAllowance: 120),
    JourneyPreflight(
      "session-welcome-sign-in", "SessionWelcomeJourneyTests/testCancelFailRetryAndExpiry",
      attachmentNames: [
        "runtime-session-welcome", "runtime-session-cancelled", "runtime-session-sign-in-failed",
        "runtime-session-checking", "runtime-session-expired",
      ],
      timeAllowance: 120),
    JourneyPreflight(
      "session-restore-storage",
      "SessionRecoveryJourneyTests/testUnreadableCredentialRetriesKeepsItOnFailedResetAndResets",
      attachmentNames: ["runtime-session-storage"], timeAllowance: 150),
    JourneyPreflight(
      "session-restore-check",
      "SessionRecoveryJourneyTests/testFailedSessionCheckRetriesAndSignInAgainRemovesTheCredential",
      attachmentNames: ["runtime-session-restoring", "runtime-session-check-failed"],
      timeAllowance: 150),
    JourneyPreflight(
      "shell-tabs", "ShellJourneyTests/testEveryTabKeepsTheOpenFolder",
      attachmentNames: ["shell-folder-open"]),
    JourneyPreflight(
      "shell-history-off", "ShellJourneyTests/testHistoryOffHidesTheHistoryTab",
      attachmentNames: ["shell-history-off"]),
    JourneyPreflight(
      "account-rating", "AccountJourneyTests/testRatingAndContactLinksOpenOnlyAfterExplicitTaps",
      attachmentNames: ["runtime-account-rating"], timeAllowance: 120),
    JourneyPreflight(
      "sign-out-downloads",
      "AccountJourneyTests/testSignOutKeepsOrRemovesDownloadsAndDismissChangesNothing",
      attachmentNames: ["runtime-sign-out-downloads", "runtime-sign-out-no-downloads"],
      timeAllowance: 180),
    JourneyPreflight(
      "account-rows", "AccountJourneyTests/testEveryAccountRowOpensAndClosesFromTopToEnd",
      timeAllowance: 180),
    JourneyPreflight(
      "account-settings-loading", "AccountJourneyTests/testSettingsLoadSlowly",
      attachmentNames: ["runtime-account-settings-loading"]),
    JourneyPreflight(
      "account-settings-states",
      "AccountJourneyTests/testSettingsLoadFailureRetriesAndFailedSavesRevertOnlineAndOffline",
      attachmentNames: [
        "runtime-account-settings-failed", "runtime-account-save-failed-unavailable",
        "runtime-account-save-failed-offline",
      ],
      timeAllowance: 120),
    JourneyPreflight(
      "analytics-prompt",
      "ProductAnalyticsPromptJourneyTests/testPromptRetriesAndSavesTheChoiceOnce",
      attachmentNames: [
        "runtime-analytics-prompt", "runtime-analytics-prompt-saving",
        "runtime-analytics-prompt-failed",
      ], timeAllowance: 180),
    JourneyPreflight(
      "analytics-prompt-swipe",
      "ProductAnalyticsPromptJourneyTests/testSwipingThePromptAwayStoresNoAnswer"),
    JourneyPreflight(
      "audio", "AudioJourneyTests/testAudioPlaysPausesChangesSpeedAndAdvancesToTheNextTrack",
      attachmentNames: ["runtime-audio-player"], timeAllowance: 120),
    JourneyPreflight(
      "downloads", "DownloadsJourneyTests/testMultiAudioDownloadOfflinePlaybackAndPositionSync",
      attachmentNames: [
        "runtime-downloads-picker", "runtime-downloads-queue", "runtime-downloads-detail",
        "runtime-downloads-remove",
      ],
      timeAllowance: 180),
    JourneyPreflight(
      "unsaved-downloads",
      "DownloadsJourneyTests/testAnUnsavedDownloadIsReportedOutsideDownloads",
      timeAllowance: 90),
    JourneyPreflight(
      "cast", "ChromecastJourneyTests/testCastSettingsSessionControlsSubtitlesAndPositionSync",
      attachmentNames: [
        "runtime-cast-settings", "runtime-cast-error", "runtime-cast-controls",
        "runtime-cast-signed-out",
      ],
      timeAllowance: 180),
    JourneyPreflight(
      "previews", "PreviewJourneyTests/testImagePDFUnsupportedAndVLCHandoffOutcomes",
      attachmentNames: [
        "runtime-preview-loading", "runtime-preview-error", "runtime-preview-image",
        "runtime-preview-image-landscape", "runtime-preview-document",
        "runtime-preview-document-middle", "runtime-preview-document-landscape",
        "runtime-preview-cannot-show", "runtime-preview-text", "runtime-preview-text-truncated",
        "runtime-preview-share-image", "runtime-preview-share-document",
        "runtime-preview-share-text",
      ],
      timeAllowance: 300),
    JourneyPreflight(
      "preview-more", "PreviewJourneyTests/testMoreMenuRenamesAndMovesTheShownFile",
      attachmentNames: [
        "runtime-preview-more-pdf", "runtime-preview-more-image", "runtime-preview-rename",
        "runtime-preview-rename-failed", "runtime-preview-moved",
      ],
      timeAllowance: 180),
    JourneyPreflight(
      "preview-paging", "PreviewJourneyTests/testSwipesBetweenFilesOfTheSameKind",
      attachmentNames: ["runtime-preview-position"],
      timeAllowance: 180),
    JourneyPreflight(
      "deep-links", "DeepLinkJourneyTests/testColdWarmAndSignedOutLinksUseExistingScreens",
      attachmentNames: [
        "runtime-deep-link-loading", "runtime-deep-link-error", "runtime-deep-link-folder",
      ],
      timeAllowance: 180),
    JourneyPreflight(
      "folder-header",
      "FilesBrowserJourneyTests/testFolderHeadersCountItemsAndBackKeepsTheParentPlace",
      attachmentNames: ["runtime-folder-header"]),
    JourneyPreflight(
      "row-menus", "FilesBrowserJourneyTests/testItemMenusSwipesAndWatchStatus",
      attachmentNames: [
        "runtime-item-swipe-left", "runtime-item-menu-folder", "runtime-item-swipe-right",
        "runtime-item-menu-vlc",
      ],
      timeAllowance: 120),
    JourneyPreflight(
      "sign-out-recovery",
      "FilesBrowserJourneyTests/testFailedSignOutLandsOnWelcomeAndNeverRestoresOnRelaunch",
      attachmentNames: ["runtime-signing-out", "runtime-sign-out-failure"], timeAllowance: 120),
    JourneyPreflight(
      "file-actions", "FilesBrowserJourneyTests/testFileActionsCreateRenameRollbackRetryAndTrash",
      attachmentNames: ["runtime-rename-failed-toast", "runtime-file-actions"],
      timeAllowance: 300),
    JourneyPreflight(
      "move-sheet", "FilesBrowserJourneyTests/testMoveSheetLevelsNameTakenNewFolderAndIntoItself",
      attachmentNames: ["runtime-move-name-taken"], timeAllowance: 120),
    JourneyPreflight(
      "trash-disabled",
      "FilesBrowserJourneyTests/testTrashDisabledUsesPermanentDeleteCopyInContextMenu"),
    JourneyPreflight(
      "trash-undo", "FilesBrowserJourneyTests/testTrashUndoSwipeAndFailedTrashKeepRowsInPlace",
      attachmentNames: ["runtime-trash-undo", "runtime-trash-failed"], timeAllowance: 120),
    JourneyPreflight(
      "trash-limit",
      "FilesBrowserJourneyTests/testTrashLimitAsksBeforeDeletingAndUnknownSettingBlocksTrash",
      attachmentNames: ["runtime-trash-limit", "runtime-trash-unknown"], timeAllowance: 120),
    JourneyPreflight(
      "trash-management", "FilesBrowserJourneyTests/testTrashManagementRestoreRetryDeleteAndEmpty",
      attachmentNames: [
        "runtime-trash-refresh-error", "runtime-trash-loaded", "runtime-trash-empty",
      ],
      timeAllowance: 90),
    JourneyPreflight(
      "sort-continuation",
      "FilesBrowserJourneyTests/testSortRoundTripAndContinuationAppendsTheSecondPage",
      attachmentNames: ["runtime-sorted-root"], timeAllowance: 90),
    JourneyPreflight(
      "sort-menu",
      "FilesBrowserJourneyTests/testSortMenuSectionsFailureRelaunchAndAccountDefault",
      attachmentNames: [
        "runtime-sort-account-default", "runtime-sort-failed", "runtime-sort-unwatched-first",
        "runtime-sort-other-folder-default",
      ],
      timeAllowance: 240),
    JourneyPreflight(
      "search-restoration",
      "FilesBrowserJourneyTests/testSearchPaginationRetryAndFolderRestoration",
      attachmentNames: ["runtime-search-results"], timeAllowance: 180),
    JourneyPreflight(
      "folder-states", "FilesBrowserJourneyTests/testFolderEmptyPagingFailedPageAndPullToRefresh",
      attachmentNames: ["runtime-folder-empty", "runtime-folder-load-more-failed"],
      timeAllowance: 240),
    JourneyPreflight(
      "folder-errors", "FilesBrowserJourneyTests/testFolderFailuresNameTheirReasonAndRecover",
      attachmentNames: ["runtime-folder-forbidden", "runtime-folder-offline"],
      timeAllowance: 180),
    JourneyPreflight(
      "folder-reconciliation",
      "FilesBrowserJourneyTests/testRenamingAndDeletingOpenFolderReconcilesOtherTabs",
      timeAllowance: 120),
    JourneyPreflight(
      "history", "HistoryJourneyTests/testHistoryPagingNavigationMutationsAndSettingGate",
      attachmentNames: [
        "runtime-history-loaded", "runtime-history-error", "runtime-history-empty",
      ],
      timeAllowance: 180),
    JourneyPreflight(
      "file-preferences",
      "FilePreferencesJourneyTests/testFilePreferencesFailureRecoveryResetAndPersistence",
      attachmentNames: [
        "runtime-file-preferences", "runtime-file-preferences-refresh", "runtime-privacy-controls",
      ],
      timeAllowance: 240),
    JourneyPreflight(
      "playback-preferences",
      "PlaybackPreferencesJourneyTests/testProxySubtitlesAndAutoplayRetryAndPersistAcrossRelaunch",
      attachmentNames: ["runtime-playback-preferences"], timeAllowance: 180),
    JourneyPreflight(
      "proxy",
      "PlaybackPreferencesJourneyTests/testProxyListWaitsOnASlowLoadAndARefusedRouteKeepsTheCheckedOne",
      attachmentNames: ["runtime-proxy-refused"], timeAllowance: 180),
    JourneyPreflight(
      "playback-method",
      "PlaybackPreferencesJourneyTests/testPlaybackMethodAppliesOnTapRevertsAFailedSaveAndPersistsAcrossRelaunch",
      attachmentNames: ["runtime-playback-method"], timeAllowance: 180),
    JourneyPreflight(
      "resume-setting",
      "PlaybackPreferencesJourneyTests/testResumeOffAsksFirstAndSavedVideosStartAtZeroInPortrait",
      attachmentNames: ["runtime-resume-off-confirm"], timeAllowance: 180),
    JourneyPreflight(
      "subtitles",
      "SubtitlesJourneyTests/testSystemMenuSelectsSubtitlesWithoutChangingAudioAndFollowsPreferences",
      attachmentNames: ["runtime-subtitles-menu", "runtime-subtitles-selected"],
      timeAllowance: 240),
    JourneyPreflight(
      "account-security", "AccountSecurityJourneyTests/testTwoFactorAppsLinkingClearDataAndDestroy",
      attachmentNames: [
        "runtime-security-recovery-codes", "runtime-security-apps", "runtime-danger-clear-data",
      ],
      timeAllowance: 240),
    JourneyPreflight(
      "inactive-account",
      "InactiveAccountJourneyTests/testNoticeShowsWhileInactiveAndClearsAfterRenewalOnReturn",
      attachmentNames: [
        "runtime-inactive-notice", "runtime-inactive-account-tab", "runtime-inactive-renewed",
      ], timeAllowance: 90),
    JourneyPreflight(
      "inactive-family",
      "InactiveAccountJourneyTests/testFamilyMemberSeesTheFamilyPlanNoticeWithoutADate"),
    JourneyPreflight(
      "inactive-no-date",
      "InactiveAccountJourneyTests/testOwnerWithoutADeletionDateSeesNoDaysLeft"),
    JourneyPreflight(
      "storage-full", "InactiveAccountJourneyTests/testFullStorageSaysSoOnAccount",
      attachmentNames: ["runtime-storage-full"]),
    JourneyPreflight(
      "active-account", "InactiveAccountJourneyTests/testActiveAccountSeesNoNotice"),
    JourneyPreflight(
      "resume-persistence", "FilesBrowserJourneyTests/testPlaybackPositionPersistsAcrossReopen"),
  ]
  static let testIdentifier =
    "PutioUITests/FilesBrowserJourneyTests/testRunnableAlphaLoop"
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
  expectedNames: [String] = BrowserJourneyContract.attachmentNames,
  fileExtension: String = "png"
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
        expectedName: name,
        fileExtension: fileExtension
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
      URL(fileURLWithPath: exportedName).pathExtension.lowercased() == fileExtension
    else {
      throw HarnessFailure(
        "XCUITest attachment \(name) has an invalid exported .\(fileExtension) filename")
    }
    selected[name] = exportedName
  }
  return selected
}

private func matchesJourneyAttachmentName(
  suggestedName: String,
  expectedName: String,
  fileExtension: String
) -> Bool {
  if suggestedName == expectedName { return true }
  let prefix = expectedName + "_"
  let suffix = "." + fileExtension
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

struct XCResultTestNode: Decodable, Sendable {
  let nodeType: String
  let name: String
  let result: String?
  let children: [XCResultTestNode]?

  var testCases: [XCResultTestNode] {
    nodeType == "Test Case" ? [self] : (children ?? []).flatMap(\.testCases)
  }

  var testBundles: [XCResultTestNode] {
    nodeType.hasSuffix("test bundle") ? [self] : (children ?? []).flatMap(\.testBundles)
  }
}

private struct XCResultTests: Decodable {
  let testNodes: [XCResultTestNode]
}

/// A test plan run must report exactly the plan's bundles, each with at least
/// one test, and fail none. Skips are allowed only while brand fonts are
/// optional: without them every font-gated test skips.
@discardableResult
func requirePassingTestPlan(
  summary summaryData: Data,
  tests testsData: Data,
  plan: TestPlan,
  allowsSkips: Bool
) throws -> String {
  let summary: XCResultTestSummary
  let bundles: [XCResultTestNode]
  do {
    summary = try JSONDecoder().decode(XCResultTestSummary.self, from: summaryData)
    bundles = try JSONDecoder().decode(XCResultTests.self, from: testsData).testNodes
      .flatMap(\.testBundles)
  } catch {
    throw HarnessFailure("decode \(plan.name) test plan results: \(error)")
  }
  let acceptable =
    allowsSkips
    ? ["Passed", "Skipped"].contains(summary.result)
    : summary.result == "Passed" && summary.skippedTests == 0
  guard acceptable, summary.totalTestCount > 0, summary.failedTests == 0 else {
    throw HarnessFailure(
      "\(plan.name) must run at least one test with no failures\(allowsSkips ? "" : " or skips"); "
        + "result=\(summary.result), total=\(summary.totalTestCount), "
        + "passed=\(summary.passedTests), failed=\(summary.failedTests), "
        + "skipped=\(summary.skippedTests), expectedFailures=\(summary.expectedFailures)"
    )
  }
  let ran = bundles.filter { !$0.testCases.isEmpty }.map(\.name)
  guard ran.sorted() == plan.targets.sorted() else {
    throw HarnessFailure(
      "\(plan.name) must run tests in exactly \(plan.targets.joined(separator: ", ")); "
        + "ran \(ran.isEmpty ? "none" : ran.joined(separator: ", "))"
    )
  }
  return plan.targets.map { target in
    let cases = bundles.filter { $0.name == target }.flatMap(\.testCases)
    let passed = cases.filter { $0.result == "Passed" }.count
    let skipped = cases.filter { $0.result == "Skipped" }.count
    return "\(target) passed \(passed)" + (skipped > 0 ? " and skipped \(skipped)" : "")
  }.joined(separator: "; ")
}

/// `simctl bootstatus` prints a status line every second; keep each status
/// change and the non-status lines.
func bootProgressSummary(_ output: String) -> String {
  var lastStatus: Substring?
  return output.split(separator: "\n").filter { line in
    guard !line.allSatisfy(\.isWhitespace) else { return false }
    guard let range = line.range(of: "Status=") else { return true }
    let status = line[range.upperBound...].prefix { $0 != "," }
    defer { lastStatus = status }
    return status != lastStatus
  }.joined(separator: "\n")
}

public struct HarnessFailure: Error, CustomStringConvertible, Sendable {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }

  public var description: String { message }
}
