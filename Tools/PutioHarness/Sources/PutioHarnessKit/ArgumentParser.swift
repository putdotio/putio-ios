import Foundation

public enum HarnessArgumentParser {
  public static let usage = """
    Usage:
      putio-harness doctor [--output text|json]
      putio-harness <build|boot|launch|exercise|screenshot|record|proof> --platform <ios|watchos|tvos|all> [--run-id ID] [--record-seconds N] [--scenario signed-out|gallery|signed-in] [--output text|json]
      putio-harness test --platform <ios|tvos> [--snapshots assert|record] [--output text|json]
      putio-harness journey --platform ios --scenario files-browser [--run-id ID] [--output text|json]
      putio-harness auth-status [--output text|json]
      putio-harness live-fixture [--output text|json]
      putio-harness publish --artifact PATH --repo OWNER/REPO --pr NUMBER [--output text|json]

    Simulator commands are headless. They never open Simulator.app.
    """

  public static func parse(_ arguments: [String]) throws -> HarnessInvocation {
    guard let commandName = arguments.first else { return .help }
    if commandName == "help" || commandName == "--help" || commandName == "-h" {
      return .help
    }

    let options = try Options(Array(arguments.dropFirst()))
    let output = try options.outputFormat()

    switch commandName {
    case "doctor":
      try options.rejectUnknown(allowing: ["output"])
      return .doctor(output: output)
    case "auth-status":
      try options.rejectUnknown(allowing: ["output"])
      return .authStatus(output: output)
    case "live-fixture":
      try options.rejectUnknown(allowing: ["output"])
      return .liveFixture(output: output)
    case "publish":
      try options.rejectUnknown(allowing: ["artifact", "repo", "pr", "output"])
      let artifact = try options.required("artifact")
      let repository = try options.required("repo")
      guard
        repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression)
          != nil
      else {
        throw HarnessFailure("publish: --repo must be OWNER/REPO")
      }
      guard let pullRequest = Int(try options.required("pr")), pullRequest > 0 else {
        throw HarnessFailure("publish: --pr must be a positive integer")
      }
      return .publish(
        artifact: artifact,
        repository: repository,
        pullRequest: pullRequest,
        output: output
      )
    case "test":
      try options.rejectUnknown(allowing: ["platform", "snapshots", "output"])
      guard let platform = HarnessPlatform(rawValue: try options.required("platform")),
        !platform.configuration.snapshotSuites.isEmpty
      else {
        throw HarnessFailure("test: --platform must be ios or tvos")
      }
      let snapshotsValue = options.value("snapshots") ?? "assert"
      guard snapshotsValue == "assert" || snapshotsValue == "record" else {
        throw HarnessFailure("--snapshots must be assert or record")
      }
      return .test(platform: platform, recordSnapshots: snapshotsValue == "record", output: output)
    case "journey":
      try options.rejectUnknown(allowing: ["platform", "scenario", "run-id", "output"])
      guard
        let platform = HarnessPlatform(rawValue: try options.required("platform")),
        platform == .ios
      else {
        throw HarnessFailure("journey: --platform must be ios")
      }
      guard let scenario = JourneyScenario(rawValue: try options.required("scenario")) else {
        throw HarnessFailure("journey: --scenario must be files-browser")
      }
      let runID = options.value("run-id")
      if let runID { try validateIdentifier(runID, label: "run id") }
      return .journey(platform: platform, scenario: scenario, runID: runID, output: output)
    default:
      guard let command = SurfaceCommand(rawValue: commandName) else {
        throw HarnessFailure("unknown command: \(commandName)\n\n\(usage)")
      }
      try options.rejectUnknown(
        allowing: ["platform", "run-id", "record-seconds", "scenario", "output"])
      let selection = try parsePlatform(try options.required("platform"))
      if command != .build, case .all = selection, command != .proof {
        throw HarnessFailure(
          "\(command.rawValue): --platform all is supported only by build and proof")
      }
      let runID = options.value("run-id")
      if let runID { try validateIdentifier(runID, label: "run id") }
      let secondsValue = options.value("record-seconds") ?? "3"
      guard let seconds = Int(secondsValue), (1...30).contains(seconds) else {
        throw HarnessFailure("--record-seconds must be between 1 and 30")
      }
      let scenarioValue = options.value("scenario") ?? CaptureScenario.signedOut.rawValue
      guard let scenario = CaptureScenario(rawValue: scenarioValue) else {
        throw HarnessFailure("--scenario must be signed-out, gallery, or signed-in")
      }
      if scenario != .signedOut, command != .screenshot, command != .record {
        throw HarnessFailure("--scenario is supported only by screenshot and record")
      }
      if scenario == .gallery,
        selection.platforms.contains(where: { $0.configuration.snapshotSuites.isEmpty })
      {
        throw HarnessFailure("--scenario gallery is supported only on ios and tvos")
      }
      if scenario == .signedIn, selection != .one(.ios) {
        throw HarnessFailure("--scenario \(scenario.rawValue) is supported only on ios")
      }
      return .surface(
        command: command,
        platforms: selection,
        runID: runID,
        recordSeconds: seconds,
        scenario: scenario,
        output: output
      )
    }
  }

  private static func parsePlatform(_ value: String) throws -> PlatformSelection {
    if value == "all" { return .all }
    guard let platform = HarnessPlatform(rawValue: value) else {
      throw HarnessFailure("--platform must be one of: ios, watchos, tvos, all")
    }
    return .one(platform)
  }

  private static func validateIdentifier(_ value: String, label: String) throws {
    guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
    else {
      throw HarnessFailure("\(label) must use 1-64 letters, numbers, dots, underscores, or hyphens")
    }
  }
}

private struct Options {
  private let values: [String: String]

  init(_ arguments: [String]) throws {
    var parsed: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      guard argument.hasPrefix("--") else {
        throw HarnessFailure("unexpected argument: \(argument)")
      }
      let key = String(argument.dropFirst(2))
      guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
        throw HarnessFailure("missing value for --\(key)")
      }
      guard parsed[key] == nil else {
        throw HarnessFailure("duplicate option: --\(key)")
      }
      parsed[key] = arguments[index + 1]
      index += 2
    }
    values = parsed
  }

  func value(_ key: String) -> String? { values[key] }

  func required(_ key: String) throws -> String {
    guard let value = values[key] else { throw HarnessFailure("missing required option: --\(key)") }
    return value
  }

  func outputFormat() throws -> OutputFormat {
    let value = values["output"] ?? "text"
    guard let output = OutputFormat(rawValue: value) else {
      throw HarnessFailure("--output must be text or json")
    }
    return output
  }

  func rejectUnknown(allowing allowed: Set<String>) throws {
    if let key = values.keys.first(where: { !allowed.contains($0) }) {
      throw HarnessFailure("unknown option: --\(key)")
    }
  }
}
