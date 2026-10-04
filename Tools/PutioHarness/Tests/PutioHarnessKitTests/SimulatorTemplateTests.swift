import Foundation
import Testing

@testable import PutioHarnessKit

private let runtime = try! JSONDecoder().decode(
  RuntimeRecord.self,
  from: Data(
    #"""
    {"name":"iOS 26.5","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","version":"26.5",
     "platform":"iOS","isAvailable":true,"supportedDeviceTypes":[
      {"name":"iPhone 17 Pro","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
       "productFamily":"iPhone"}]}
    """#.utf8))

/// Runs `simulatorTemplate` against a fake `xcrun` that lists the template
/// only when `existing` is set, recording every simctl invocation.
private func withFakeTemplateSimctl(
  existing: String?, _ body: (SimulatorHarness) throws -> String?
) throws -> (template: String?, calls: [String]) {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "putio-simulator-template-\(UUID().uuidString.lowercased())")
  let bin = root.appending(path: "bin")
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let log = root.appending(path: "calls")
  let name = simulatorTemplateName(
    runtime: runtime.identifier, deviceType: runtime.supportedDeviceTypes[0].identifier)
  let listed = existing.map { #"{"udid":"\#($0)","name":"\#(name)"}"# } ?? ""
  let script = """
    #!/bin/sh
    echo "$@" >> "\(log.path)"
    case "$2" in
      list) echo '{"devices":{"\(runtime.identifier)":[\(listed)]}}';;
      create) echo NEW-TEMPLATE;;
    esac
    """
  let xcrun = bin.appending(path: "xcrun")
  try script.write(to: xcrun, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun.path)
  let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
  let harness = SimulatorHarness(
    context: RepositoryContext(root: root),
    runner: ProcessRunner(environment: ["PATH": "\(bin.path):\(originalPath)"]))
  let template = try body(harness)
  let calls =
    (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
  return (template, calls)
}

struct SimulatorTemplateTests {
  private let enabled = ["PUTIO_SIMULATOR_TEMPLATES": "1"]

  @Test func existingTemplateIsReusedWithoutBooting() throws {
    let run = try withFakeTemplateSimctl(existing: "CACHED-TEMPLATE") { harness in
      try harness.simulatorTemplate(
        platform: .ios, runtime: runtime, deviceType: runtime.supportedDeviceTypes[0],
        environment: enabled)
    }
    #expect(run.template == "CACHED-TEMPLATE")
    #expect(run.calls == ["simctl list devices -j"])
  }

  @Test func missingTemplateIsCreatedBootedOnceAndShutDown() throws {
    let run = try withFakeTemplateSimctl(existing: nil) { harness in
      try harness.simulatorTemplate(
        platform: .ios, runtime: runtime, deviceType: runtime.supportedDeviceTypes[0],
        environment: enabled)
    }
    #expect(run.template == "NEW-TEMPLATE")
    #expect(
      run.calls == [
        "simctl list devices -j",
        "simctl create putio-template-iOS-26-5-iPhone-17-Pro"
          + " com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
          + " com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        "simctl boot NEW-TEMPLATE",
        "simctl bootstatus NEW-TEMPLATE -b -d",
        "simctl shutdown NEW-TEMPLATE",
      ])
  }

  @Test(arguments: [
    (HarnessPlatform.ios, [String: String]()),
    (HarnessPlatform.tvos, ["PUTIO_SIMULATOR_TEMPLATES": "1"]),
  ])
  func templatesStayOffOutsideCIAndForOtherPlatforms(
    platform: HarnessPlatform, environment: [String: String]
  ) throws {
    let run = try withFakeTemplateSimctl(existing: "CACHED-TEMPLATE") { harness in
      try harness.simulatorTemplate(
        platform: platform, runtime: runtime, deviceType: runtime.supportedDeviceTypes[0],
        environment: environment)
    }
    #expect(run.template == nil)
    #expect(run.calls.isEmpty)
  }
}
