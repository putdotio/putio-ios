import Foundation
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
    #expect(appleTV.runtimeDescription == "tvOS 26.1 (23J582)")
    #expect(appleTV.isPaired)
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

private struct StubbedToolchain {
  let root: URL
  let context: RepositoryContext
  let runner: ProcessRunner
  let log: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "putio-device-\(UUID().uuidString.lowercased())")
    let bin = root.appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appending(path: "Putio.xcworkspace"), withIntermediateDirectories: true)
    context = RepositoryContext(root: root)
    let product = context.derivedData.appending(
      path: "Build/Products/Debug-appletvos/PutioTV.app")
    try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: product.appending(path: "PutioTV"))
    let fixture = root.appending(path: "devices.json")
    try Data(deviceListFixture.utf8).write(to: fixture)
    log = root.appending(path: "calls")
    for (tool, body) in [
      ("xcrun", #"[ "$1 $2" = "devicectl list" ] && cat "$PUTIO_DEVICE_FIXTURE""#),
      ("xcodebuild", ":"),
    ] {
      let executable = bin.appending(path: tool)
      try """
      #!/bin/sh
      printf '%s\\n' "CALL \(tool)" "$@" >> "$PUTIO_DEVICE_CALL_LOG"
      \(body)
      """.write(to: executable, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    runner = ProcessRunner(environment: [
      "PATH": "\(bin.path):\(originalPath)",
      "PUTIO_DEVICE_CALL_LOG": log.path,
      "PUTIO_DEVICE_FIXTURE": fixture.path,
    ])
  }

  func harness(environment: [String: String]) -> PhysicalDeviceHarness {
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

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

struct PhysicalDeviceBuildTests {
  @Test func buildsSignedDebugAppForSelectedAppleTV() throws {
    let toolchain = try StubbedToolchain()
    defer { toolchain.remove() }
    let run = try toolchain.harness(environment: ["PUTIO_DEVELOPMENT_TEAM": "ABCDE12345"])
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
      try toolchain.harness(environment: ["PUTIO_DEVELOPMENT_TEAM": "ABCDE12345"])
        .execute(.build, platform: .tvos, query: "Bedroom", requestedRunID: nil, liveSeconds: 3)
    } throws: { error in
      (error as? HarnessFailure)?.message.contains("is not paired") == true
    }
    #expect(try toolchain.calls().allSatisfy { $0.first != "xcodebuild" })
  }
}
