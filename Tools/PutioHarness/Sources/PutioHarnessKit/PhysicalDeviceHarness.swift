import Foundation

struct PairedDevice: Equatable, Sendable {
  let identifier: String
  let udid: String?
  let name: String
  let platform: String?
  let productType: String?
  let osVersion: String?
  let osBuild: String?
  let isPaired: Bool

  var selector: String { udid ?? identifier }
  var label: String { "\(name) (\(selector))" }

  var isEligibleAppleTV: Bool { platform == "tvOS" && isPaired }

  func proofProvenance() throws -> (model: String, runtime: String) {
    guard let platform, let productType, let osVersion, let osBuild else {
      throw HarnessFailure(
        "devicectl did not report the model, OS version, and OS build for \(label); unlock the device and retry"
      )
    }
    return (productType, "\(platform) \(osVersion) (\(osBuild))")
  }
}

private struct DeviceCtlProcessList: Decodable {
  struct Result: Decodable {
    let runningProcesses: [RunningProcess]
  }

  struct RunningProcess: Decodable {
    let executable: String?
    let processIdentifier: Int
  }

  let result: Result
}

func decodeRunningAppProcessIdentifiers(_ data: Data, appName: String) throws -> [Int] {
  let list: DeviceCtlProcessList
  do {
    list = try JSONDecoder().decode(DeviceCtlProcessList.self, from: data)
  } catch {
    throw HarnessFailure("decode devicectl process list: \(error)")
  }
  return list.result.runningProcesses
    .filter { $0.executable?.contains("/\(appName)/") == true }
    .map(\.processIdentifier)
}

private struct DeviceCtlDeviceList: Decodable {
  struct Result: Decodable {
    let devices: [Device]
  }

  struct Device: Decodable {
    let identifier: String
    let properties: Properties?
  }

  struct Properties: Decodable {
    let connection: Connection?
    let hardware: Hardware?
    let software: Software?
    let state: State?
  }

  struct Connection: Decodable {
    let pairingState: String?
  }

  struct Hardware: Decodable {
    let platform: String?
    let productType: String?
    let udid: String?
  }

  struct Software: Decodable {
    struct Version: Decodable {
      let stringValue: String?
    }

    struct Builds: Decodable {
      struct Build: Decodable {
        let name: String?
      }

      let buildVersion: Build?
    }

    let osVersionNumber: Version?
    let osBuildVersions: Builds?
  }

  struct State: Decodable {
    let name: String?
  }

  let result: Result
}

func decodePairedDevices(_ data: Data) throws -> [PairedDevice] {
  let list: DeviceCtlDeviceList
  do {
    list = try JSONDecoder().decode(DeviceCtlDeviceList.self, from: data)
  } catch {
    throw HarnessFailure("decode devicectl device list: \(error)")
  }
  return list.result.devices.map { device in
    let properties = device.properties
    return PairedDevice(
      identifier: device.identifier,
      udid: properties?.hardware?.udid,
      name: properties?.state?.name ?? device.identifier,
      platform: properties?.hardware?.platform,
      productType: properties?.hardware?.productType,
      osVersion: properties?.software?.osVersionNumber?.stringValue,
      osBuild: properties?.software?.osBuildVersions?.buildVersion?.name,
      isPaired: properties?.connection?.pairingState == "paired"
    )
  }
}

/// devicectl reports names with typographic apostrophes and no-break spaces,
/// which a typed `--device` value rarely reproduces.
private func normalizedDeviceName(_ name: String) -> String {
  name.replacingOccurrences(of: "\u{00A0}", with: " ")
    .replacingOccurrences(of: "\u{2019}", with: "'")
    .lowercased()
}

func selectPairedDevice(
  matching query: String,
  platform: HarnessPlatform,
  in devices: [PairedDevice]
) throws -> PairedDevice {
  let target = try PhysicalDeviceHarness.target(for: platform)
  let pairedTargets = devices.filter(\.isEligibleAppleTV)
  let available =
    pairedTargets.isEmpty
    ? "no \(target.deviceFamily) is paired; pair one as described in docs/harness.md"
    : "paired \(target.deviceFamily) devices: "
      + pairedTargets.map(\.label).joined(separator: ", ")
  var matches = devices.filter { device in
    device.udid?.caseInsensitiveCompare(query) == .orderedSame
      || device.identifier.caseInsensitiveCompare(query) == .orderedSame
      || normalizedDeviceName(device.name) == normalizedDeviceName(query)
  }
  let eligibleMatches = matches.filter(\.isEligibleAppleTV)
  if matches.count > 1, eligibleMatches.count == 1 { matches = eligibleMatches }
  guard let device = matches.first else {
    throw HarnessFailure("no device matches --device \(query); \(available)")
  }
  guard matches.count == 1 else {
    throw HarnessFailure(
      "--device \(query) matches \(matches.count) devices; pass a UDID: "
        + matches.map(\.label).joined(separator: ", "))
  }
  guard device.platform == target.devicePlatform else {
    throw HarnessFailure(
      "\(device.label) is not an \(target.deviceFamily) (platform \(device.platform ?? "unknown")); \(available)"
    )
  }
  guard device.isPaired else {
    throw HarnessFailure(
      "\(device.label) is not paired with this Mac; pair it as described in docs/harness.md")
  }
  return device
}

struct PhysicalDeviceTarget: Equatable, Sendable {
  let devicePlatform: String
  let deviceFamily: String
  let productDirectory: String
}

struct PhysicalDeviceHarness {
  static let commands: Set<SurfaceCommand> = [.build, .launch, .proof]
  static let developmentTeamVariable = "PUTIO_DEVELOPMENT_TEAM"

  private let context: RepositoryContext
  private let simulator: SimulatorHarness
  private let runner: ProcessRunner
  private let fileManager: FileManager
  private let environment: [String: String]

  init(
    context: RepositoryContext,
    simulator: SimulatorHarness,
    runner: ProcessRunner = ProcessRunner(),
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.context = context
    self.simulator = simulator
    self.runner = runner
    self.fileManager = fileManager
    self.environment = environment
  }

  static func target(for platform: HarnessPlatform) throws -> PhysicalDeviceTarget {
    guard platform == .tvos else {
      throw HarnessFailure("--device is supported only with --platform tvos")
    }
    return PhysicalDeviceTarget(
      devicePlatform: "tvOS", deviceFamily: "Apple TV", productDirectory: "Debug-appletvos")
  }

  func execute(
    _ command: SurfaceCommand,
    platform: HarnessPlatform,
    query: String,
    requestedRunID: String?,
    liveSeconds: Int
  ) throws -> SurfaceRun {
    switch command {
    case .build:
      let device = try resolveDevice(query, platform: platform)
      try build(platform, device: device)
      return SurfaceRun(
        platform: platform, artifacts: [],
        message: "built \(platform.configuration.scheme) for \(device.label)")
    case .launch:
      let device = try resolveDevice(query, platform: platform)
      try build(platform, device: device)
      try install(platform, device: device)
      let scratch = context.root.appending(
        path: "build/harness/\(UUID().uuidString.lowercased())")
      try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
      defer { try? fileManager.removeItem(at: scratch) }
      try launchAndObserve(
        platform, device: device, directory: scratch, liveSeconds: liveSeconds)
      return SurfaceRun(
        platform: platform, artifacts: [],
        message:
          "launch confirmed \(platform.configuration.bundleIdentifier) stayed running on \(device.label)"
      )
    case .proof:
      return try proof(
        platform, query: query, requestedRunID: requestedRunID, liveSeconds: liveSeconds)
    case .boot, .exercise, .screenshot, .record:
      throw HarnessFailure("--device is supported only by build, launch, and proof")
    }
  }

  func resolveDevice(_ query: String, platform: HarnessPlatform) throws -> PairedDevice {
    let output = try runner.checked(
      "xcrun",
      [
        "devicectl", "list", "devices", "--timeout", "30", "--json-output", "-",
        "--omit-deprecated-fields-in-json",
      ],
      context: "list devices known to Xcode"
    )
    return try selectPairedDevice(
      matching: query, platform: platform, in: decodePairedDevices(Data(output.stdout.utf8)))
  }

  func build(_ platform: HarnessPlatform, device: PairedDevice) throws {
    try simulator.requireGeneratedWorkspace()
    guard let team = environment[Self.developmentTeamVariable],
      team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil
    else {
      throw HarnessFailure(
        "set \(Self.developmentTeamVariable) to the 10-character Apple development team ID that signs debug builds for \(device.label)"
      )
    }
    try fileManager.createDirectory(at: context.derivedData, withIntermediateDirectories: true)
    let config = platform.configuration
    _ = try runner.checked(
      "xcodebuild",
      [
        "build",
        "-workspace", "Putio.xcworkspace",
        "-scheme", config.scheme,
        "-configuration", "Debug",
        "-destination", "id=\(device.selector)",
        "-derivedDataPath", context.derivedData.path,
        "-allowProvisioningUpdates",
        "-allowProvisioningDeviceRegistration",
        "DEVELOPMENT_TEAM=\(team)",
      ],
      currentDirectory: context.root,
      context: "build \(platform.rawValue) scheme \(config.scheme) for \(device.label)"
    )
    try simulator.requireNonemptyDirectory(
      try appURL(for: platform), context: "built \(platform.rawValue) device app")
  }

  private func appURL(for platform: HarnessPlatform) throws -> URL {
    context.derivedData
      .appending(path: "Build/Products")
      .appending(path: try Self.target(for: platform).productDirectory)
      .appending(path: platform.configuration.appName)
  }

  private func install(_ platform: HarnessPlatform, device: PairedDevice) throws {
    _ = try runner.checked(
      "xcrun",
      [
        "devicectl", "device", "install", "app", "--device", device.selector,
        try appURL(for: platform).path,
      ],
      context: "install \(platform.rawValue) app on \(device.label)"
    )
  }

  private func proof(
    _ platform: HarnessPlatform,
    query: String,
    requestedRunID: String?,
    liveSeconds: Int
  ) throws -> SurfaceRun {
    let runID = try requestedRunID ?? simulator.defaultRunID()
    let sourceRevision = try simulator.pinProofSourceRevision()
    try simulator.regenerateWorkspace()
    try simulator.requireCleanSource()
    try simulator.requireRevision(sourceRevision)
    let device = try resolveDevice(query, platform: platform)
    let provenance = try device.proofProvenance()
    try build(platform, device: device)
    let directory = context.proofRoot.appending(path: runID).appending(path: platform.rawValue)
    guard !fileManager.fileExists(atPath: directory.path) else {
      throw HarnessFailure(
        "proof path already exists: \(directory.path); choose a new --run-id")
    }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      try install(platform, device: device)
      let screenshot = try launchAndObserve(
        platform, device: device, directory: directory, liveSeconds: liveSeconds)
      try simulator.requireCleanSource()
      try simulator.requireRevision(sourceRevision)
      let manifest = try simulator.writeManifest(
        ProofManifest(
          schemaVersion: 2,
          runID: runID,
          commit: sourceRevision,
          createdAt: ISO8601DateFormatter().string(from: Date()),
          command: SurfaceCommand.proof.rawValue,
          platform: platform,
          scheme: platform.configuration.scheme,
          bundleIdentifier: platform.configuration.bundleIdentifier,
          runtime: provenance.runtime,
          deviceType: provenance.model,
          simulatorName: nil,
          fixtureSet: "device-installed-state-v1",
          artifacts: [try simulator.artifact(for: screenshot)]
        ),
        directory: directory
      )
      return SurfaceRun(
        platform: platform,
        artifacts: [screenshot, manifest],
        message:
          "captured device proof for \(platform.rawValue) on \(device.label) in \(context.relativePath(for: directory))"
      )
    } catch {
      let log = directory.appending(path: "app.console.log")
      let diagnostics =
        (try? String(contentsOf: log, encoding: .utf8)).map {
          "app console tail:\n" + $0.split(separator: "\n").suffix(40).joined(separator: "\n")
        } ?? ""
      try? fileManager.removeItem(at: directory)
      guard !diagnostics.isEmpty else { throw error }
      throw HarnessFailure("\(error)\n\(diagnostics)")
    }
  }

  /// Launches with the app's stdio bridged to devicectl, so the bridge process
  /// lives exactly as long as the app and doubles as the liveness signal. No
  /// app arguments follow the bundle identifier, where devicectl could read them
  /// as its own options; the app's default scenario is signed-out.
  @discardableResult
  private func launchAndObserve(
    _ platform: HarnessPlatform,
    device: PairedDevice,
    directory: URL,
    liveSeconds: Int
  ) throws -> URL {
    let config = platform.configuration
    try terminateRunningApp(platform, device: device)
    let baseline = directory.appending(path: ".baseline.png")
    try captureScreenshot(device: device, to: baseline, context: "capture pre-launch screen")
    defer { try? fileManager.removeItem(at: baseline) }
    let baselinePixels = try simulator.decodedPixels(at: baseline)

    let console = try runner.start(
      "xcrun",
      [
        "devicectl", "device", "process", "launch", "--device", device.selector,
        "--terminate-existing", "--console", config.bundleIdentifier,
      ]
    )
    let log = directory.appending(path: "app.console.log")
    var consoleLogWritten = false
    func stopConsole() {
      guard !consoleLogWritten else { return }
      consoleLogWritten = true
      let output = console.interruptAndWait()
      try? Data(output.combinedOutput.utf8).write(to: log, options: .atomic)
    }
    defer { stopConsole() }

    let screenshot = directory.appending(path: "launch.png")
    let deadline = Date().addingTimeInterval(30)
    var rendered = false
    repeat {
      guard console.isRunning else {
        stopConsole()
        throw HarnessFailure(
          "\(config.bundleIdentifier) exited on \(device.label) before its first rendered frame")
      }
      if (try? captureScreenshot(device: device, to: screenshot, context: "poll launch")) != nil,
        let pixels = try? simulator.decodedPixels(at: screenshot),
        pixels.differsMeaningfully(from: baselinePixels),
        pixels.visibleContentPixelCount >= pixels.minimumContentPixelCount
      {
        rendered = true
        break
      }
      Thread.sleep(forTimeInterval: 0.5)
    } while Date() < deadline
    guard rendered else {
      throw HarnessFailure(
        "\(config.bundleIdentifier) did not change the screen on \(device.label) within 30 seconds"
      )
    }

    let liveDeadline = Date().addingTimeInterval(TimeInterval(liveSeconds))
    while Date() < liveDeadline {
      guard console.isRunning else {
        stopConsole()
        throw HarnessFailure("\(config.bundleIdentifier) exited on \(device.label) during proof")
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
    try captureScreenshot(device: device, to: screenshot, context: "capture launched screen")
    let finalPixels = try simulator.requireMeaningfulScreenshot(
      screenshot, context: "device screenshot")
    guard finalPixels.differsMeaningfully(from: baselinePixels) else {
      throw HarnessFailure(
        "\(config.bundleIdentifier) is no longer on screen on \(device.label) at proof capture")
    }
    guard console.isRunning else {
      throw HarnessFailure(
        "\(config.bundleIdentifier) exited on \(device.label) before proof capture completed")
    }
    return screenshot
  }

  /// A relaunch can redraw the screen an earlier run left behind, so the
  /// pre-launch baseline must be captured with the app gone.
  private func terminateRunningApp(_ platform: HarnessPlatform, device: PairedDevice) throws {
    let appName = platform.configuration.appName
    let identifiers = try runningAppProcessIdentifiers(appName, device: device)
    guard !identifiers.isEmpty else { return }
    for identifier in identifiers {
      _ = try runner.checked(
        "xcrun",
        [
          "devicectl", "device", "process", "terminate", "--device", device.selector,
          "--pid", String(identifier),
        ],
        context: "terminate running \(appName) on \(device.label)"
      )
    }
    let deadline = Date().addingTimeInterval(10)
    repeat {
      Thread.sleep(forTimeInterval: 0.5)
      if try runningAppProcessIdentifiers(appName, device: device).isEmpty { return }
    } while Date() < deadline
    throw HarnessFailure("\(appName) did not terminate on \(device.label) within 10 seconds")
  }

  private func runningAppProcessIdentifiers(_ appName: String, device: PairedDevice) throws
    -> [Int]
  {
    let output = try runner.checked(
      "xcrun",
      [
        "devicectl", "device", "info", "processes", "--device", device.selector,
        "--json-output", "-",
      ],
      context: "list processes on \(device.label)"
    )
    return try decodeRunningAppProcessIdentifiers(Data(output.stdout.utf8), appName: appName)
  }

  private func captureScreenshot(device: PairedDevice, to url: URL, context: String) throws {
    _ = try runner.checked(
      "xcrun",
      [
        "devicectl", "device", "capture", "screenshot", "--device", device.selector,
        "--destination", url.path,
      ],
      context: "\(context) on \(device.label)"
    )
  }
}
