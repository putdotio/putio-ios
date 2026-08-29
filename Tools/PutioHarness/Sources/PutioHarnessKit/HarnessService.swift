import Foundation

public enum HarnessResponse: Sendable {
  case help(String)
  case doctor(DoctorReport)
  case result(HarnessResult)
}

public struct HarnessService {
  private let context: RepositoryContext
  private let simulator: SimulatorHarness
  private let live: LiveAdapters

  public init(context: RepositoryContext) {
    self.context = context
    simulator = SimulatorHarness(context: context)
    live = LiveAdapters(context: context)
  }

  public func execute(_ invocation: HarnessInvocation) throws -> HarnessResponse {
    switch invocation {
    case .help:
      return .help(HarnessArgumentParser.usage)
    case .doctor:
      return .doctor(HarnessDoctor(context: context).inspect())
    case .authStatus:
      return .result(try live.authStatus())
    case .liveFixture:
      return .result(try live.provisionFixture())
    case .publish(let artifact, let repository, let pullRequest, _):
      return .result(
        try live.publish(artifact: artifact, repository: repository, pullRequest: pullRequest)
      )
    case .surface(
      let command, let selection, let requestedRunID, let recordSeconds, let scenario, _):
      return .result(
        try executeSurface(
          command: command,
          selection: selection,
          requestedRunID: requestedRunID,
          recordSeconds: recordSeconds,
          scenario: scenario
        )
      )
    case .test(let platform, let recordSnapshots, _):
      let run = try simulator.test(platform, recordSnapshots: recordSnapshots)
      return .result(
        HarnessResult(
          command: "test",
          platforms: [run.platform.rawValue],
          artifacts: run.artifacts.map(context.relativePath(for:)),
          message: run.message
        )
      )
    case .journey(let platform, let scenario, let requestedRunID, _):
      let runID = try requestedRunID ?? simulator.defaultRunID()
      let sourceRevision = try simulator.pinProofSourceRevision()
      let run = try simulator.journey(
        platform,
        scenario: scenario,
        runID: runID,
        sourceRevision: sourceRevision
      )
      return .result(
        HarnessResult(
          command: "journey",
          platforms: [run.platform.rawValue],
          artifacts: run.artifacts.map(context.relativePath(for:)),
          message: run.message
        )
      )
    }
  }

  private func executeSurface(
    command: SurfaceCommand,
    selection: PlatformSelection,
    requestedRunID: String?,
    recordSeconds: Int,
    scenario: CaptureScenario
  ) throws -> HarnessResult {
    let platforms = selection.platforms
    var runs: [SurfaceRun] = []
    var iosProductAvailable = false

    switch command {
    case .build:
      for platform in platforms {
        runs.append(
          try simulator.build(platform, iosCompanionAvailable: iosProductAvailable)
        )
        if platform == .ios || platform == .watchos { iosProductAvailable = true }
      }
    case .boot:
      guard let platform = platforms.first else { throw HarnessFailure("no platform selected") }
      runs.append(try simulator.boot(platform))
    case .launch:
      guard let platform = platforms.first else { throw HarnessFailure("no platform selected") }
      runs.append(try simulator.launch(platform))
    case .exercise:
      guard let platform = platforms.first else { throw HarnessFailure("no platform selected") }
      runs.append(try simulator.exercise(platform))
    case .screenshot, .record, .proof:
      let runID = try requestedRunID ?? simulator.defaultRunID()
      let sourceRevision = try simulator.pinProofSourceRevision()
      for platform in platforms {
        runs.append(
          try simulator.capture(
            platform,
            command: command,
            runID: runID,
            recordSeconds: recordSeconds,
            scenario: scenario,
            iosCompanionAvailable: iosProductAvailable,
            sourceRevision: sourceRevision
          )
        )
        if platform == .ios || platform == .watchos { iosProductAvailable = true }
      }
    }

    let artifacts = runs.flatMap(\.artifacts).map(context.relativePath(for:))
    return HarnessResult(
      command: command.rawValue,
      platforms: runs.map(\.platform.rawValue),
      artifacts: artifacts,
      message: runs.map(\.message).joined(separator: "; ")
    )
  }
}

public enum HarnessOutput {
  public static func requestedErrorFormat(arguments: [String]) -> OutputFormat {
    guard let outputIndex = arguments.firstIndex(of: "--output"),
      arguments.indices.contains(outputIndex + 1)
    else { return .text }
    return OutputFormat(rawValue: arguments[outputIndex + 1]) ?? .text
  }

  public static func format(for invocation: HarnessInvocation) -> OutputFormat {
    switch invocation {
    case .help: .text
    case .doctor(let output): output
    case .surface(_, _, _, _, _, let output): output
    case .test(_, _, let output): output
    case .journey(_, _, _, let output): output
    case .authStatus(let output): output
    case .liveFixture(let output): output
    case .publish(_, _, _, let output): output
    }
  }

  public static func render(_ response: HarnessResponse, format: OutputFormat) throws -> String {
    switch (response, format) {
    case (.help(let usage), _):
      usage
    case (.doctor(let report), .json):
      try encode(redacted(report))
    case (.doctor(let report), .text):
      (["doctor: \(report.status)"]
        + report.checks.map { check in
          "\(check.status.rawValue): \(check.name): \(redact(check.detail))"
        }).joined(separator: "\n")
    case (.result(let result), .json):
      try encode(result)
    case (.result(let result), .text):
      ([result.message] + result.artifacts.map { "artifact: \($0)" }).joined(separator: "\n")
    }
  }

  public static func error(_ error: Error, json: Bool) -> String {
    let message = redact(String(describing: error))
    if json {
      let result = HarnessResult(status: "failed", command: "error", message: message)
      return (try? encode(result)) ?? #"{"status":"failed","message":"harness error"}"#
    }
    return "putio-harness: \(message)"
  }

  public static func redact(
    _ message: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String {
    var result = message
    let sensitiveKeyMarkers = ["TOKEN", "SECRET", "PASSWORD", "API_KEY", "APIKEY", "AUTHORIZATION"]
    let sensitiveValues = environment.compactMap { key, value in
      sensitiveKeyMarkers.contains(where: { key.uppercased().contains($0) }) && value.count >= 4
        ? value : nil
    }.sorted { $0.count > $1.count }
    for value in sensitiveValues {
      result = result.replacingOccurrences(of: value, with: "[REDACTED]")
    }
    if let home = environment["HOME"], home.count > 1 {
      result = result.replacingOccurrences(of: home, with: "$HOME")
    }

    let replacements = [
      (
        pattern: #"(?i)(authorization\s*[:=]\s*(?:bearer|basic)\s+)[^\s,}&]+"#,
        template: "$1[REDACTED]"
      ),
      (
        pattern:
          "(?i)([\"']?(?:access[_-]?token|refresh[_-]?token|api[_-]?key|password|secret|token|authorization)[\"']?\\s*[:=]\\s*)\"(?:\\\\.|[^\"\\\\])*\"",
        template: "$1\"[REDACTED]\""
      ),
      (
        pattern:
          "(?i)([\"']?(?:access[_-]?token|refresh[_-]?token|api[_-]?key|password|secret|token|authorization)[\"']?\\s*[:=]\\s*)'(?:\\\\.|[^'\\\\])*'",
        template: "$1'[REDACTED]'"
      ),
      (
        pattern:
          "(?i)([\"']?(?:access[_-]?token|refresh[_-]?token|api[_-]?key|password|secret|token|authorization)[\"']?\\s*[:=]\\s*)(?![\"'])[^\\s&,}]+",
        template: "$1[REDACTED]"
      ),
    ]
    for replacement in replacements {
      guard let regex = try? NSRegularExpression(pattern: replacement.pattern) else { continue }
      let range = NSRange(result.startIndex..., in: result)
      result = regex.stringByReplacingMatches(
        in: result, range: range, withTemplate: replacement.template)
    }
    return result
  }

  private static func redacted(_ report: DoctorReport) -> DoctorReport {
    DoctorReport(
      checks: report.checks.map { check in
        DoctorCheck(
          name: check.name,
          status: check.status,
          required: check.required,
          detail: redact(check.detail)
        )
      })
  }

  private static func encode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
}
