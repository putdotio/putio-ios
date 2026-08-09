import Foundation

public enum HarnessArgumentParser {
  public static let usage = """
    Usage:
      putio-harness doctor [--output text|json]
      putio-harness <build|launch|exercise|screenshot|record|proof> --platform <ios|watchos|tvos|all> [--run-id ID] [--record-seconds N] [--output text|json]
      putio-harness auth-status [--profile NAME] [--output text|json]
      putio-harness live-fixture [--profile NAME] [--name NAME] [--output text|json]
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
      try options.rejectUnknown(allowing: ["profile", "output"])
      return .authStatus(profile: options.value("profile") ?? "devs-fe-auto", output: output)
    case "live-fixture":
      try options.rejectUnknown(allowing: ["profile", "name", "output"])
      let name = options.value("name") ?? "putio-ios-harness"
      try validateIdentifier(name, label: "fixture name")
      return .liveFixture(
        profile: options.value("profile") ?? "devs-fe-auto",
        name: name,
        output: output
      )
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
    default:
      guard let command = SurfaceCommand(rawValue: commandName) else {
        throw HarnessFailure("unknown command: \(commandName)\n\n\(usage)")
      }
      try options.rejectUnknown(allowing: ["platform", "run-id", "record-seconds", "output"])
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
      return .surface(
        command: command,
        platforms: selection,
        runID: runID,
        recordSeconds: seconds,
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
