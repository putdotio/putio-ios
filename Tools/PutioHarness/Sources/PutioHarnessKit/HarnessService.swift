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
    case .surface(let command, let selection, let requestedRunID, let recordSeconds, _):
      return .result(
        try executeSurface(
          command: command,
          selection: selection,
          requestedRunID: requestedRunID,
          recordSeconds: recordSeconds
        )
      )
    }
  }

  private func executeSurface(
    command: SurfaceCommand,
    selection: PlatformSelection,
    requestedRunID: String?,
    recordSeconds: Int
  ) throws -> HarnessResult {
    let platforms = selection.platforms
    var runs: [SurfaceRun] = []

    switch command {
    case .build:
      for platform in platforms { runs.append(try simulator.build(platform)) }
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
      for platform in platforms {
        runs.append(
          try simulator.capture(
            platform,
            command: command,
            runID: runID,
            recordSeconds: recordSeconds
          )
        )
      }
    }

    let artifacts = runs.flatMap(\.artifacts).map { url in
      url.path.replacingOccurrences(of: context.root.path + "/", with: "")
    }
    return HarnessResult(
      command: command.rawValue,
      platforms: runs.map(\.platform.rawValue),
      artifacts: artifacts,
      message: runs.map(\.message).joined(separator: "; ")
    )
  }
}

public enum HarnessOutput {
  public static func format(for invocation: HarnessInvocation) -> OutputFormat {
    switch invocation {
    case .help: .text
    case .doctor(let output): output
    case .surface(_, _, _, _, let output): output
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
      try encode(report)
    case (.doctor(let report), .text):
      (["doctor: \(report.status)"]
        + report.checks.map { check in
          "\(check.status.rawValue): \(check.name): \(check.detail)"
        }).joined(separator: "\n")
    case (.result(let result), .json):
      try encode(result)
    case (.result(let result), .text):
      ([result.message] + result.artifacts.map { "artifact: \($0)" }).joined(separator: "\n")
    }
  }

  public static func error(_ error: Error, json: Bool) -> String {
    let message = String(describing: error)
    if json {
      let result = HarnessResult(status: "failed", command: "error", message: message)
      return (try? encode(result)) ?? #"{"status":"failed","message":"harness error"}"#
    }
    return "putio-harness: \(message)"
  }

  private static func encode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
}
