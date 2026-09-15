import Foundation
import Testing

@testable import PutioHarnessKit

private func withFakeXcodebuild(
  environment: [String: String],
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
  let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
  let runner = ProcessRunner(environment: [
    "PATH": "\(bin.path):\(originalPath)",
    "PUTIO_BUILD_CALL_LOG": log.path,
  ])
  try body(SimulatorHarness(context: context, runner: runner, environment: environment))
  return try String(contentsOf: log, encoding: .utf8)
    .components(separatedBy: "CALL\n").dropFirst()
    .map { $0.split(separator: "\n").map(String.init) }
}

struct SimulatorBuildTests {
  @Test(arguments: [[:], ["CI": "true"], ["CI": "false"], ["GITHUB_ACTIONS": "true"]])
  func allAppBuildsPreserveCIArchitectures(environment: [String: String]) throws {
    let calls = try withFakeXcodebuild(environment: environment) { harness in
      _ = try harness.build(.ios)
      _ = try harness.build(.watchos, iosCompanionAvailable: true)
      _ = try harness.build(.tvos)
    }
    let expectedSchemes = ["Putio", "PutioNightly", "PutioWatch", "PutioTV"]
    let expectedDestinations = [
      "generic/platform=iOS Simulator", "generic/platform=iOS Simulator",
      "generic/platform=watchOS Simulator", "generic/platform=tvOS Simulator",
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
      #expect(
        arguments.filter { $0.hasPrefix("ARCHS=") }
          == (environment.isEmpty ? ["ARCHS=$(NATIVE_ARCH_ACTUAL)"] : []))
    }
  }

  @Test func standaloneWatchBuildAlsoBuildsNativeCompanion() throws {
    let calls = try withFakeXcodebuild(environment: [:]) { harness in
      _ = try harness.build(.watchos)
    }
    let schemes = try calls.map { arguments in
      let index = try #require(arguments.firstIndex(of: "-scheme"))
      #expect(arguments.contains("ARCHS=$(NATIVE_ARCH_ACTUAL)"))
      return arguments[index + 1]
    }
    #expect(schemes == ["Putio", "PutioNightly", "PutioWatch"])
  }
}
