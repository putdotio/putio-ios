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
        exerciseURL: "putio-harness://exercise"
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
        deviceFamily: "Apple Watch",
        exerciseURL: "putio-harness://exercise"
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
        exerciseURL: "putio-harness://exercise"
      )
    }
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
  public let exerciseURL: String

  public init(
    scheme: String,
    bundleIdentifier: String,
    sdk: String,
    destination: String,
    productDirectory: String,
    appName: String,
    runtimePlatform: String,
    deviceFamily: String,
    exerciseURL: String
  ) {
    self.scheme = scheme
    self.bundleIdentifier = bundleIdentifier
    self.sdk = sdk
    self.destination = destination
    self.productDirectory = productDirectory
    self.appName = appName
    self.runtimePlatform = runtimePlatform
    self.deviceFamily = deviceFamily
    self.exerciseURL = exerciseURL
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

public enum SurfaceCommand: String, CaseIterable, Equatable, Sendable {
  case build
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
    output: OutputFormat
  )
  case authStatus(output: OutputFormat)
  case liveFixture(output: OutputFormat)
  case publish(artifact: String, repository: String, pullRequest: Int, output: OutputFormat)
}

enum LiveFixtureContract {
  static let profile = "devs-fe-auto"
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

public struct HarnessFailure: Error, CustomStringConvertible, Sendable {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }

  public var description: String { message }
}
