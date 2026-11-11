import Foundation
import Testing

@testable import PutioHarnessKit

private func withFakeXcodebuild(
  _ body: (SimulatorHarness) throws -> Void
) throws -> [[String]] {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "putio-simulator-build-\(UUID().uuidString.lowercased())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let bin = root.appending(path: "bin")
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: root.appending(path: "Putio.xcworkspace"), withIntermediateDirectories: true)
  let context = RepositoryContext(root: root)
  for platform in HarnessPlatform.allCases {
    let config = platform.configuration
    let product = context.derivedData.appending(
      path: "Build/Products/\(config.productDirectory)/\(config.appName)")
    try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: product.appending(path: "executable"))
  }
  let log = root.appending(path: "calls")
  let executable = bin.appending(path: "xcodebuild")
  try """
  #!/bin/sh
  printf '%s\\n' CALL "$@" >> "$PUTIO_BUILD_CALL_LOG"
  """.write(to: executable, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755], ofItemAtPath: executable.path)
  // Simulator work fails at its first step, so tests can see what ran before it.
  let simulatorTools = bin.appending(path: "xcrun")
  try """
  #!/bin/sh
  printf '%s\\n' CALL xcrun "$@" >> "$PUTIO_BUILD_CALL_LOG"
  exit 1
  """.write(to: simulatorTools, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755], ofItemAtPath: simulatorTools.path)
  let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
  let runner = ProcessRunner(environment: [
    "PATH": "\(bin.path):\(originalPath)",
    "PUTIO_BUILD_CALL_LOG": log.path,
  ])
  try body(SimulatorHarness(context: context, runner: runner))
  return try String(contentsOf: log, encoding: .utf8)
    .components(separatedBy: "CALL\n").dropFirst()
    .map { $0.split(separator: "\n").map(String.init) }
}

@Suite(.serialized)
struct SimulatorBuildTests {
  @Test func everyAppBuildCompilesOnlyTheHostArchitecture() throws {
    let calls = try withFakeXcodebuild { harness in
      _ = try harness.build(.ios)
      _ = try harness.build(.watchos, iosCompanionAvailable: true)
      _ = try harness.build(.tvos)
    }
    let expectedSchemes = ["Putio", "PutioWatch", "PutioTV"]
    let expectedDestinations = [
      "generic/platform=iOS Simulator", "generic/platform=watchOS Simulator",
      "generic/platform=tvOS Simulator",
    ]
    try #require(calls.count == expectedSchemes.count)
    for (index, arguments) in calls.enumerated() {
      #expect(arguments.first == "build")
      let schemeIndex = try #require(arguments.firstIndex(of: "-scheme"))
      #expect(arguments[schemeIndex + 1] == expectedSchemes[index])
      let destinationIndex = try #require(arguments.firstIndex(of: "-destination"))
      #expect(arguments[destinationIndex + 1] == expectedDestinations[index])
      let configurationIndex = try #require(arguments.firstIndex(of: "-configuration"))
      #expect(arguments[configurationIndex + 1] == "Debug")
      #expect(arguments.filter { $0.hasPrefix("ARCHS=") } == ["ARCHS=$(NATIVE_ARCH_ACTUAL)"])
    }
  }

  @Test func testSuitesCompileForTheHostArchitecture() throws {
    let calls = try withFakeXcodebuild { harness in
      #expect(throws: HarnessFailure.self) {
        try harness.test(.ios, recordSnapshots: false, environment: [:])
      }
    }
    let builds = calls.filter { $0.first != "xcrun" }
    try #require(builds.count == 2)
    for (index, target) in ["PutioSnapshotTests", "PutioFeatureTests"].enumerated() {
      let arguments = builds[index]
      #expect(arguments.first == "build-for-testing")
      #expect(arguments.contains("-only-testing:\(target)"))
      let destinationIndex = try #require(arguments.firstIndex(of: "-destination"))
      #expect(arguments[destinationIndex + 1] == "generic/platform=iOS Simulator")
      #expect(arguments.contains("ARCHS=$(NATIVE_ARCH_ACTUAL)"))
    }
    #expect(calls.contains { $0.starts(with: ["xcrun", "simctl"]) })
  }

  @Test func aFailedBuildDeletesTheSimulatorBootedAlongsideIt() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "putio-simulator-overlap-\(UUID().uuidString.lowercased())")
    let bin = root.appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appending(path: "Putio.xcworkspace"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = root.appending(path: "calls")
    let devices = root.appending(path: "devices")
    try Data().write(to: devices)
    let runtimes = #"""
      {"runtimes":[{"name":"iOS 27.2","identifier":"ios-27-2","version":"27.2","platform":"iOS",
        "isAvailable":true,"runtimeRoot":"/nonexistent","supportedDeviceTypes":[
        {"name":"iPhone 17","identifier":"iphone-17","productFamily":"iPhone"}]}]}
      """#.replacingOccurrences(of: "\n", with: "")
    let scripts = [
      "xcrun": """
      #!/bin/sh
      echo "$@" >> "\(log.path)"
      add() { u="UDID-$(wc -l < "\(log.path)" | tr -d ' ')"; echo "{\\"udid\\":\\"$u\\",\\"name\\":\\"$1\\"}" >> "\(devices.path)"; echo "$u"; }
      case "$2" in
        list)
          if [ "$4" = runtimes ]; then echo '\(runtimes)'; exit 0; fi
          echo "{\\"devices\\":{\\"ios-27-2\\":[$(paste -sd, "\(devices.path)")]}}";;
        create) add "$3";;
        clone) add "$4";;
        delete) grep -v "\\"$3\\"" "\(devices.path)" > "\(devices.path).next"; mv "\(devices.path).next" "\(devices.path)";;
      esac
      """,
      "xcodebuild": """
      #!/bin/sh
      if [ "$1" = -version ]; then echo 27.2; exit 0; fi
      exit 65
      """,
    ]
    for (name, script) in scripts {
      let executable = bin.appending(path: name)
      try script.write(to: executable, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let harness = SimulatorHarness(
      context: RepositoryContext(root: root),
      runner: ProcessRunner(environment: ["PATH": "\(bin.path):\(originalPath)"]))

    #expect(throws: HarnessFailure.self) {
      try harness.test(.ios, recordSnapshots: false, environment: [:])
    }

    let calls = try String(contentsOf: log, encoding: .utf8)
    #expect(calls.contains("simctl bootstatus"))
    let remaining = try String(contentsOf: devices, encoding: .utf8)
    #expect(!remaining.contains("putio-harness-"))
  }

  @Test func standaloneWatchBuildAlsoBuildsNativeCompanion() throws {
    let calls = try withFakeXcodebuild { harness in
      _ = try harness.build(.watchos)
    }
    let schemes = try calls.map { arguments in
      let index = try #require(arguments.firstIndex(of: "-scheme"))
      #expect(arguments.contains("ARCHS=$(NATIVE_ARCH_ACTUAL)"))
      return arguments[index + 1]
    }
    #expect(schemes == ["Putio", "PutioWatch"])
  }
}
