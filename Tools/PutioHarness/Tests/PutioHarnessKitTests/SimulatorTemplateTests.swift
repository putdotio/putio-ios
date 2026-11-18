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

private let templateName = simulatorTemplateName(
  runtime: runtime.identifier, deviceType: runtime.supportedDeviceTypes[0].identifier)

private func listedDevice(_ udid: String, name: String = templateName, state: String = "Shutdown")
  -> String
{
  #"{"udid":"\#(udid)","name":"\#(name)","state":"\#(state)","isAvailable":true}"#
}

private func withFakeTemplateSimctl(
  existing: String?, listing extra: [String] = [], failing: String? = nil,
  _ body: (SimulatorHarness, URL) throws -> String?
) throws -> (template: String?, calls: [String], error: Error?) {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "putio-simulator-template-\(UUID().uuidString.lowercased())")
  let bin = root.appending(path: "bin")
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let log = root.appending(path: "calls")
  let listed = ((existing.map { [listedDevice($0)] } ?? []) + extra).joined(separator: ",")
  let script = """
    #!/bin/sh
    echo "$@" >> "\(log.path)"
    case "$2" in
      list) echo '{"devices":{"\(runtime.identifier)":[\(listed)]}}';;
      create) echo NEW-TEMPLATE;;
      \(failing ?? "-") ) exit 1;;
    esac
    """
  let xcrun = bin.appending(path: "xcrun")
  try script.write(to: xcrun, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun.path)
  let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
  let harness = SimulatorHarness(
    context: RepositoryContext(root: root),
    runner: ProcessRunner(environment: ["PATH": "\(bin.path):\(originalPath)"]),
    lifecycle: SimulatorLifecycle())
  let template: String?
  let failure: Error?
  do {
    template = try body(harness, root.appending(path: "template.lock"))
    failure = nil
  } catch {
    guard failing != nil else { throw error }
    template = nil
    failure = error
  }
  let calls =
    (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
  return (template, calls, failure)
}

struct SimulatorTemplateTests {
  private let enabled = ["PUTIO_SIMULATOR_TEMPLATES": "1"]

  @Test func existingTemplateIsReusedWithoutBooting() throws {
    let run = try withFakeTemplateSimctl(existing: "CACHED-TEMPLATE") { harness, lock in
      try harness.simulatorTemplate(
        platform: .ios, runtime: runtime, deviceType: runtime.supportedDeviceTypes[0],
        environment: enabled, lock: lock)
    }
    #expect(run.template == "CACHED-TEMPLATE")
    #expect(run.calls == ["simctl list devices -j"])
  }

  @Test(arguments: [
    ["PUTIO_SIMULATOR_TEMPLATES": "1"], [:], ["CI": "false"],
    ["CI": "true", "PUTIO_SIMULATOR_TEMPLATES": "true"],
  ])
  func missingTemplateIsMadeUnderATemporaryNameThenRenamed(environment: [String: String])
    throws
  {
    let run = try withFakeTemplateSimctl(existing: nil) { harness, lock in
      try harness.simulatorTemplate(
        platform: .ios, runtime: runtime, deviceType: runtime.supportedDeviceTypes[0],
        environment: environment, lock: lock)
    }
    let name = "putio-template-iOS-26-5-iPhone-17-Pro"
    #expect(run.template == "NEW-TEMPLATE")
    #expect(run.calls.count == 6)
    #expect(run.calls.first == "simctl list devices -j")
    let create = run.calls.dropFirst().first ?? ""
    #expect(create.hasPrefix("simctl create putio-pending-\(name)-"))
    #expect(
      create.hasSuffix(
        " com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
          + " com.apple.CoreSimulator.SimRuntime.iOS-26-5"))
    #expect(
      Array(run.calls.dropFirst(2)) == [
        "simctl boot NEW-TEMPLATE",
        "simctl bootstatus NEW-TEMPLATE -b -d",
        "simctl shutdown NEW-TEMPLATE",
        "simctl rename NEW-TEMPLATE \(name)",
      ])
  }

  @Test func failedFirstBootDeletesThePendingDevice() throws {
    let run = try withFakeTemplateSimctl(existing: nil, failing: "bootstatus") { harness, lock in
      try harness.simulatorTemplate(
        platform: .ios, runtime: runtime, deviceType: runtime.supportedDeviceTypes[0],
        environment: enabled, lock: lock)
    }
    #expect(run.template == nil)
    let failure = try #require(run.error as? HarnessFailure)
    #expect(failure.message.hasPrefix("wait for ios template Simulator failed"))
    #expect(
      Array(run.calls.dropFirst(2)) == [
        "simctl boot NEW-TEMPLATE",
        "simctl bootstatus NEW-TEMPLATE -b -d",
        "simctl shutdown NEW-TEMPLATE",
        "simctl delete NEW-TEMPLATE",
        "simctl list devices -j",
      ])
    #expect(!run.calls.contains { $0.hasPrefix("simctl rename") })
  }

  @Test func localRunsReuseTheTemplateByDefault() throws {
    let run = try withFakeTemplateSimctl(existing: "CACHED-TEMPLATE") { harness, lock in
      try harness.simulatorTemplate(
        platform: .ios, runtime: runtime, deviceType: runtime.supportedDeviceTypes[0],
        environment: [:], lock: lock)
    }
    #expect(run.template == "CACHED-TEMPLATE")
    #expect(run.calls == ["simctl list devices -j"])
  }

  @Test(arguments: [
    (HarnessPlatform.ios, ["CI": "true"]),
    (HarnessPlatform.ios, ["CI": "1"]),
    (HarnessPlatform.ios, ["PUTIO_SIMULATOR_TEMPLATES": "0"]),
    (HarnessPlatform.ios, ["PUTIO_SIMULATOR_TEMPLATES": "false"]),
    (HarnessPlatform.tvos, ["PUTIO_SIMULATOR_TEMPLATES": "1"]),
  ])
  func templatesStayOffWhenCIHasNoneOptedOutOrOtherPlatforms(
    platform: HarnessPlatform, environment: [String: String]
  ) throws {
    let run = try withFakeTemplateSimctl(existing: "CACHED-TEMPLATE") { harness, lock in
      try harness.simulatorTemplate(
        platform: platform, runtime: runtime, deviceType: runtime.supportedDeviceTypes[0],
        environment: environment, lock: lock)
    }
    #expect(run.template == nil)
    #expect(run.calls.isEmpty)
  }

  @Test func aKilledRunsPendingDeviceIsDeletedBeforeTheTemplateIsReused() throws {
    let run = try withFakeTemplateSimctl(
      existing: "CACHED-TEMPLATE",
      listing: [listedDevice("LEFTOVER", name: "putio-pending-\(templateName)-dead0000")]
    ) { harness, lock in
      try harness.simulatorTemplate(
        platform: .ios, runtime: runtime, deviceType: runtime.supportedDeviceTypes[0],
        environment: enabled, lock: lock)
    }
    #expect(run.template == "CACHED-TEMPLATE")
    #expect(
      run.calls == [
        "simctl list devices -j",
        "simctl shutdown LEFTOVER",
        "simctl delete LEFTOVER",
        "simctl list devices -j",
      ])
  }

  @Test func aBootedTemplateFallsBackToAFreshDevice() throws {
    let run = try withFakeTemplateSimctl(
      existing: nil, listing: [listedDevice("BUSY-TEMPLATE", state: "Booted")]
    ) { harness, lock in
      try harness.simulatorTemplate(
        platform: .ios, runtime: runtime, deviceType: runtime.supportedDeviceTypes[0],
        environment: enabled, lock: lock)
    }
    #expect(run.template == nil)
    #expect(run.calls == ["simctl list devices -j"])
  }
}
