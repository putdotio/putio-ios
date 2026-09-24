import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import PutioHarnessKit

private let pairedAppleTVUDID = "00008110-000A1B2C3D4E5F60"
private let unpairedAppleTVUDID = "00008110-000F6E5D4C3B2A10"
private let iPhoneUDID = "00008130-0001122334455667"

private func deviceJSON(
  identifier: String,
  name: String,
  platform: String,
  productType: String,
  udid: String,
  pairingState: String,
  osVersion: String = "26.1",
  osBuild: String = "23J582"
) -> String {
  """
  {
    "identifier": "\(identifier)",
    "properties": {
      "connection": {
        "pairingState": "\(pairingState)",
        "state": "disconnected",
        "transportType": "localNetwork"
      },
      "hardware": {
        "platform": "\(platform)",
        "productType": "\(productType)",
        "udid": "\(udid)"
      },
      "software": {
        "osBuildVersions": { "buildVersion": { "name": "\(osBuild)" } },
        "osVersionNumber": { "stringValue": "\(osVersion)" }
      },
      "state": { "bootState": "booted", "name": "\(name)" }
    }
  }
  """
}

private let deviceListFixture = """
  {
    "info": { "commandType": "devicectl.list.devices", "jsonVersion": 5, "outcome": "success" },
    "result": {
      "devices": [
        \(deviceJSON(
          identifier: "11111111-1111-4111-8111-111111111111", name: "Test\u{2019}s iPhone",
          platform: "iOS", productType: "iPhone16,1", udid: iPhoneUDID, pairingState: "paired")),
        \(deviceJSON(
          identifier: "22222222-2222-4222-8222-222222222222", name: "Living\u{00A0}Room",
          platform: "tvOS", productType: "AppleTV14,1", udid: pairedAppleTVUDID,
          pairingState: "paired")),
        \(deviceJSON(
          identifier: "33333333-3333-4333-8333-333333333333", name: "Bedroom",
          platform: "tvOS", productType: "AppleTV11,1", udid: unpairedAppleTVUDID,
          pairingState: "unpaired"))
      ]
    }
  }
  """

private func fixtureDevices() throws -> [PairedDevice] {
  try decodePairedDevices(Data(deviceListFixture.utf8))
}

private func selectionFailure(_ query: String, in devices: [PairedDevice]) throws -> String {
  do {
    _ = try selectPairedDevice(matching: query, platform: .tvos, in: devices)
  } catch let failure as HarnessFailure {
    return failure.message
  }
  Issue.record("--device \(query) unexpectedly selected a device")
  return ""
}

struct PairedDeviceSelectionTests {
  @Test func decodesProvenanceFromDevicectl() throws {
    let appleTV = try #require(try fixtureDevices().first { $0.udid == pairedAppleTVUDID })
    #expect(appleTV.productType == "AppleTV14,1")
    let provenance = try appleTV.proofProvenance()
    #expect(provenance.model == "AppleTV14,1")
    #expect(provenance.runtime == "tvOS 26.1 (23J582)")
    #expect(appleTV.isPaired)
  }

  @Test func refusesProofWithoutReportedOSBuild() throws {
    let device = PairedDevice(
      identifier: "55555555-5555-4555-8555-555555555555", udid: pairedAppleTVUDID,
      name: "Living Room", platform: "tvOS", productType: "AppleTV14,1", osVersion: "26.1",
      osBuild: nil, isPaired: true)
    #expect(throws: HarnessFailure.self) { try device.proofProvenance() }
  }

  @Test func prefersTheOnlyPairedAppleTVAmongSameNamedDevices() throws {
    let iPhone = PairedDevice(
      identifier: "66666666-6666-4666-8666-666666666666", udid: "00008130-0000000000000002",
      name: "Living Room", platform: "iOS", productType: "iPhone16,1", osVersion: "26.1",
      osBuild: "23B85", isPaired: true)
    let device = try selectPairedDevice(
      matching: "Living Room", platform: .tvos, in: fixtureDevices() + [iPhone])
    #expect(device.selector == pairedAppleTVUDID)
  }

  @Test(arguments: [
    pairedAppleTVUDID, pairedAppleTVUDID.lowercased(), "22222222-2222-4222-8222-222222222222",
    "Living Room", "living room",
  ])
  func selectsPairedAppleTV(query: String) throws {
    let device = try selectPairedDevice(matching: query, platform: .tvos, in: fixtureDevices())
    #expect(device.selector == pairedAppleTVUDID)
  }

  @Test func rejectsUnpairedAppleTV() throws {
    let message = try selectionFailure("Bedroom", in: fixtureDevices())
    #expect(message.contains("is not paired"))
    #expect(message.contains("docs/harness.md"))
  }

  @Test func rejectsNonTVDeviceAndListsPairedAppleTVs() throws {
    let message = try selectionFailure("Test's iPhone", in: fixtureDevices())
    #expect(message.contains("is not an Apple TV (platform iOS)"))
    #expect(message.contains(pairedAppleTVUDID))
    #expect(!message.contains(unpairedAppleTVUDID))
  }

  @Test func rejectsUnknownDevice() throws {
    let message = try selectionFailure("Kitchen", in: fixtureDevices())
    #expect(message.hasPrefix("no device matches --device Kitchen"))
    #expect(message.contains("Living\u{00A0}Room (\(pairedAppleTVUDID))"))
  }

  @Test func explainsPairingWhenNoAppleTVIsPaired() throws {
    let devices = try fixtureDevices().filter { $0.udid != pairedAppleTVUDID }
    let message = try selectionFailure(pairedAppleTVUDID, in: devices)
    #expect(message.contains("no Apple TV is paired"))
  }

  @Test func requiresUDIDForDuplicateNames() throws {
    let devices = try fixtureDevices()
    let duplicate = try #require(devices.first { $0.udid == pairedAppleTVUDID })
    let twin = PairedDevice(
      identifier: "44444444-4444-4444-8444-444444444444", udid: "00008110-0000000000000001",
      name: duplicate.name, platform: "tvOS", productType: "AppleTV14,1", osVersion: "26.1",
      osBuild: "23J582", isPaired: true)
    let message = try selectionFailure("Living Room", in: devices + [twin])
    #expect(message.contains("matches 2 devices; pass a UDID"))
  }
}

struct PhysicalDeviceArgumentTests {
  @Test(arguments: [SurfaceCommand.build, .launch, .proof])
  func parsesAppleTVDevice(command: SurfaceCommand) throws {
    let invocation = try HarnessArgumentParser.parse([
      command.rawValue, "--platform", "tvos", "--device", "Living Room", "--output", "json",
    ])
    #expect(
      invocation
        == .surface(
          command: command,
          platforms: .one(.tvos),
          runID: nil,
          recordSeconds: 3,
          scenario: .signedOut,
          output: .json,
          device: "Living Room"
        )
    )
  }

  @Test(arguments: [
    (["proof", "--platform", "ios", "--device", "x"], "only with --platform tvos"),
    (["build", "--platform", "all", "--device", "x"], "only with --platform tvos"),
    (["boot", "--platform", "tvos", "--device", "x"], "only by build, launch, and proof"),
    (["screenshot", "--platform", "tvos", "--device", "x"], "only by build, launch, and proof"),
    (["proof", "--platform", "tvos", "--device", " "], "must be a device UDID"),
    (
      ["journey", "--platform", "tvos", "--scenario", "device-sign-in", "--device", "x"],
      "unknown option: --device"
    ),
  ])
  func rejectsUnsupportedDeviceTargets(arguments: [String], expected: String) {
    #expect {
      try HarnessArgumentParser.parse(arguments)
    } throws: { error in
      (error as? HarnessFailure)?.message.contains(expected) == true
    }
  }

  @Test func simulatorInvocationsCarryNoDevice() throws {
    let invocation = try HarnessArgumentParser.parse(["proof", "--platform", "tvos"])
    guard case .surface(_, _, _, _, _, _, let device) = invocation else {
      Issue.record("expected a surface invocation")
      return
    }
    #expect(device == nil)
  }
}

private func writePNG(to url: URL, gray: CGFloat) throws {
  let width = 64
  let height = 36
  let context = try #require(
    CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let image = try #require(context.makeImage())
  let destination = try #require(
    CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  try #require(CGImageDestinationFinalize(destination))
}

/// Fakes `xcodebuild`, `devicectl`, and a device whose screen shows the app
/// only while the stubbed app process runs.
private struct StubbedToolchain {
  let root: URL
  let tools: URL
  let context: RepositoryContext
  let runner: ProcessRunner
  let log: URL
  let appRunning: URL

  init() throws {
    let base = FileManager.default.temporaryDirectory.appending(
      path: "putio-device-\(UUID().uuidString.lowercased())")
    root = base.appending(path: "repo")
    tools = base.appending(path: "tools")
    let bin = tools.appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appending(path: "Putio.xcworkspace"), withIntermediateDirectories: true)
    context = RepositoryContext(root: root)
    let product = context.derivedData.appending(
      path: "Build/Products/Debug-appletvos/PutioTV.app")
    try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: product.appending(path: "PutioTV"))
    try Data(deviceListFixture.utf8).write(to: tools.appending(path: "devices.json"))
    try writePNG(to: tools.appending(path: "home.png"), gray: 0)
    try writePNG(to: tools.appending(path: "app.png"), gray: 0.5)
    log = tools.appending(path: "calls")
    appRunning = tools.appending(path: "app-running")
    let xcrun = #"""
      [ "$1" = devicectl ] || exit 64
      case "$2 $3" in
        "list devices") cat "$STUB/devices.json" ;;
        "device install") ;;
        "device info")
          if [ -f "$STUB/app-running" ]; then
            printf '{"result":{"runningProcesses":[{"executable":"file:///private/var/containers/Bundle/Application/X/PutioTV.app/PutioTV","processIdentifier":42}]}}'
          else
            printf '{"result":{"runningProcesses":[]}}'
          fi ;;
        "device process")
          if [ "$4" = terminate ]; then rm -f "$STUB/app-running"; exit 0; fi
          touch "$STUB/app-running"
          trap 'rm -f "$STUB/app-running"; exit 0' INT TERM
          echo "app console line"
          while :; do sleep 0.1; done ;;
        "device capture")
          while [ "$1" != --destination ]; do shift; done
          if [ -f "$STUB/app-running" ]; then cp "$STUB/app.png" "$2"; else cp "$STUB/home.png" "$2"; fi ;;
        *) exit 64 ;;
      esac
      """#
    for (tool, body) in [("xcrun", xcrun), ("xcodebuild", ":")] {
      let executable = bin.appending(path: tool)
      try """
      #!/bin/sh
      entry="CALL \(tool)"
      for argument in "$@"; do entry="$entry
      $argument"; done
      printf '%s\\n' "$entry" >> "$STUB/calls"
      \(body)
      """.write(to: executable, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    runner = ProcessRunner(environment: [
      "PATH": "\(bin.path):\(originalPath)",
      "STUB": tools.path,
    ])
  }

  func harness(
    environment: [String: String] = ["PUTIO_DEVELOPMENT_TEAM": "ABCDE12345"]
  ) -> PhysicalDeviceHarness {
    PhysicalDeviceHarness(
      context: context,
      simulator: SimulatorHarness(context: context, runner: runner, environment: environment),
      runner: runner,
      environment: environment
    )
  }

  func calls() throws -> [[String]] {
    guard FileManager.default.fileExists(atPath: log.path) else { return [] }
    return try String(contentsOf: log, encoding: .utf8)
      .components(separatedBy: "CALL ").dropFirst()
      .map { $0.split(separator: "\n").map(String.init) }
  }

  func commitRepository() throws {
    let scripts = root.appending(path: "scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let generate = scripts.appending(path: "generate.sh")
    try "#!/bin/sh\n".write(to: generate, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: generate.path)
    try "build/\nPutio.xcworkspace/\n".write(
      to: root.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
    for arguments in [
      ["init", "-q"], ["add", "-A"],
      [
        "-c", "user.name=harness", "-c", "user.email=harness@example.invalid", "commit", "-qm",
        "fixture",
      ],
    ] {
      _ = try runner.checked("git", arguments, currentDirectory: root, context: "git fixture")
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
  }
}

struct PhysicalDeviceBuildTests {
  @Test func buildsSignedDebugAppForSelectedAppleTV() throws {
    let toolchain = try StubbedToolchain()
    defer { toolchain.remove() }
    let run = try toolchain.harness()
      .execute(.build, platform: .tvos, query: "living room", requestedRunID: nil, liveSeconds: 3)
    #expect(run.message == "built PutioTV for Living\u{00A0}Room (\(pairedAppleTVUDID))")

    let calls = try toolchain.calls()
    try #require(calls.count == 2)
    #expect(calls[0].first == "xcrun")
    #expect(calls[0].contains("--omit-deprecated-fields-in-json"))
    let build = calls[1]
    #expect(build.first == "xcodebuild")
    let destination = try #require(build.firstIndex(of: "-destination"))
    #expect(build[destination + 1] == "id=\(pairedAppleTVUDID)")
    let scheme = try #require(build.firstIndex(of: "-scheme"))
    #expect(build[scheme + 1] == "PutioTV")
    #expect(build.contains("DEVELOPMENT_TEAM=ABCDE12345"))
    #expect(build.contains("-allowProvisioningUpdates"))
    #expect(!build.contains { $0.hasPrefix("ARCHS=") })
  }

  @Test(arguments: [[:], ["PUTIO_DEVELOPMENT_TEAM": "not-a-team"]])
  func requiresDevelopmentTeamBeforeBuilding(environment: [String: String]) throws {
    let toolchain = try StubbedToolchain()
    defer { toolchain.remove() }
    #expect {
      try toolchain.harness(environment: environment)
        .execute(
          .build, platform: .tvos, query: pairedAppleTVUDID, requestedRunID: nil,
          liveSeconds: 3)
    } throws: { error in
      (error as? HarnessFailure)?.message.contains("PUTIO_DEVELOPMENT_TEAM") == true
    }
    #expect(try toolchain.calls().allSatisfy { $0.first != "xcodebuild" })
  }

  @Test func refusesUnpairedAppleTVBeforeBuilding() throws {
    let toolchain = try StubbedToolchain()
    defer { toolchain.remove() }
    #expect {
      try toolchain.harness()
        .execute(.build, platform: .tvos, query: "Bedroom", requestedRunID: nil, liveSeconds: 3)
    } throws: { error in
      (error as? HarnessFailure)?.message.contains("is not paired") == true
    }
    #expect(try toolchain.calls().allSatisfy { $0.first != "xcodebuild" })
  }
}

struct PhysicalDeviceRunTests {
  @Test func relaunchesAnAppAlreadyOnScreen() throws {
    let toolchain = try StubbedToolchain()
    defer { toolchain.remove() }
    try Data().write(to: toolchain.appRunning)
    let run = try toolchain.harness()
      .execute(
        .launch, platform: .tvos, query: pairedAppleTVUDID, requestedRunID: nil,
        liveSeconds: 1)
    #expect(run.message.hasPrefix("launch confirmed io.put.dev.tvos stayed running"))
    let devicectl = try toolchain.calls().filter { $0.first == "xcrun" }.map { $0.dropFirst() }
    let terminate = try #require(devicectl.firstIndex { $0.contains("terminate") })
    let baseline = try #require(devicectl.firstIndex { $0.contains("screenshot") })
    #expect(terminate < baseline)
    #expect(devicectl[terminate].contains("42"))
    let launch = try #require(devicectl.first { $0.contains("launch") })
    #expect(launch.last == "io.put.dev.tvos")
    #expect(!FileManager.default.fileExists(atPath: toolchain.appRunning.path))
  }

  @Test func proofRecordsAppleTVProvenance() throws {
    let toolchain = try StubbedToolchain()
    defer { toolchain.remove() }
    try toolchain.commitRepository()
    let run = try toolchain.harness()
      .execute(
        .proof, platform: .tvos, query: "Living Room", requestedRunID: "device-proof",
        liveSeconds: 1)
    let directory = toolchain.context.proofRoot.appending(path: "device-proof/tvos")
    let manifestURL = directory.appending(path: "manifest.json")
    #expect(run.artifacts.map(\.lastPathComponent) == ["launch.png", "manifest.json"])
    let manifest = try JSONDecoder().decode(
      ProofManifest.self, from: Data(contentsOf: manifestURL))
    #expect(manifest.deviceType == "AppleTV14,1")
    #expect(manifest.runtime == "tvOS 26.1 (23J582)")
    #expect(manifest.schemaVersion == 2)
    #expect(manifest.fixtureSet == "device-installed-state-v1")
    #expect(manifest.simulatorName == nil)
    #expect(manifest.artifacts.map(\.kind) == ["screenshot"])
    #expect(
      !String(decoding: try Data(contentsOf: manifestURL), as: UTF8.self)
        .contains("simulatorName"))
    let console = try String(
      contentsOf: directory.appending(path: "app.console.log"), encoding: .utf8)
    #expect(console.contains("app console line"))
  }
}
